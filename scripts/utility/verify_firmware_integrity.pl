#!/usr/bin/perl

# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use Digest::SHA;
use File::Temp qw/ tempdir /;
use File::Find;
use Getopt::Long;
use Sort::Versions;
use Sys::Syslog qw(:standard :macros);

# Force immediate output flushing
$| = 1;

# Initialize syslog connection
openlog('ohb-verify-fw', 'ndelay,pid', 'local0');

# --- Configuration ---
my $VERSION = "latest";
my $alert_on_missing_default = 1; # Set to 1 to email on missing files, 0 to only email on integrity mismatch

my $cmd_servers;
my $cmd_to_addresses;
my $cmd_alert_on_missing_val;
my $cmd_upgrade;

GetOptions(
    "s=s" => \$cmd_servers,          # Comma-separated list of server URLs
    "t=s" => \$cmd_to_addresses,     # Comma-separated list of email addresses
    "a:i" => \$cmd_alert_on_missing_val, # 0 or 1, overrides default
    "u"   => \$cmd_upgrade,          # Self-upgrade flag
) or die "Error in command line arguments\n";

my $servers_str = $cmd_servers // $ENV{'OHB_VERIFY_SERVERS'};
die "Error: OHB_VERIFY_SERVERS environment variable or -s option is not set. Please provide a comma-separated list of server URLs.\n"
    unless defined $servers_str && $servers_str ne '';

my @ohb_servers = split(/\s*,\s*/, $servers_str);

my $to_list = $cmd_to_addresses // $ENV{'OHB_VERIFY_EMAILS'};

my $alert_on_missing = defined $cmd_alert_on_missing_val ? $cmd_alert_on_missing_val : $alert_on_missing_default;

# State for aggregated reporting
my $aggregated_alert_body = "";
my $has_integrity_failure = 0;

# Upstream Source info
# The hostname is used in the From: header of alert emails.
my $owner         = "openhamclock";
my $repo          = "hamclock";
my $upstream_host = "clearskyinstitute.com"; # The name we patch BACK
my $hostname      = $ENV{'HOST_HOSTNAME'} // `hostname` // 'localhost';
chomp($hostname);

my $ua = LWP::UserAgent->new(timeout => 60);
$ua->agent("OHB-External-Verifier/1.0");

# --- Self Upgrade ---
if ($cmd_upgrade) {
    logger("Checking for script updates from komacke/open-hamclock-backend...");
    my $api_url = "https://api.github.com/repos/komacke/open-hamclock-backend/releases/latest";
    my $resp = $ua->get($api_url);
    if ($resp->is_success) {
        my $data = decode_json($resp->decoded_content);
        my $latest_tag = $data->{tag_name};
        my $clean_tag = $latest_tag;
        $clean_tag =~ s/^v//i;

        if (versioncmp($clean_tag, $VERSION) > 0) {
            logger("New version $latest_tag available (current: $VERSION). Upgrading...");

            # Find the versioned asset in the release metadata
            my $asset_name = "verify_firmware_integrity-$latest_tag.pl";
            my ($asset) = grep { $_->{name} eq $asset_name } @{$data->{assets}};

            if (!$asset) {
                logger("Error: Asset $asset_name not found in release $latest_tag assets.", 1);
                exit 1;
            }

            my $dl_resp = $ua->get($asset->{browser_download_url}, ':content_file' => $0);
            if ($dl_resp->is_success) {
                logger("Upgrade successful. Script replaced at $0. Please restart.", 1);
                exit 0;
            } else {
                logger("Error downloading upgrade: " . $dl_resp->status_line, 1);
                exit 1;
            }
        } else {
            logger("Script is up to date ($VERSION).");
        }
    } else {
        logger("Error checking for updates: " . $resp->status_line, 1);
    }
    exit 0;
}

sub logger {
    my ($msg, $force) = @_;
    chomp($msg);

    # Record to syslog with appropriate priority
    my $pri = ($msg =~ /^(Error|CRITICAL|ALERT)/i) ? LOG_ERR : LOG_INFO;
    syslog($pri, '%s', $msg);

    # Suppress output if email is configured and we are not in an interactive terminal.
    # We still allow output if $force is set (e.g., when sendmail fails).
    return if $to_list && ! -t STDOUT && !$force;

    print "[".scalar(gmtime)."] $msg\n";
}

# Helper to send email alerts on integrity failure
sub send_alert {
    my ($subject, $body) = @_;

    # Accumulate alerts for the final report
    $aggregated_alert_body .= "======================================================================\n";
    $aggregated_alert_body .= "ALERT: $subject\n";
    $aggregated_alert_body .= "======================================================================\n";
    $aggregated_alert_body .= "$body\n\n";

    # Mark if we encountered a critical integrity mismatch
    $has_integrity_failure = 1 if $subject =~ /Integrity Failure/i;

    logger("Queued alert for summary email: $subject");
}

# Internal helper to dispatch the final aggregated email
sub dispatch_final_report {
    return unless $aggregated_alert_body;

    if (!$to_list) {
        logger("CRITICAL: Alerts generated but no email configured (OHB_VERIFY_EMAILS or -t missing).", 1);
        logger("AGGREGATED ALERTS:\n$aggregated_alert_body", 1);
        return;
    }

    my $final_subject = $has_integrity_failure 
        ? "CRITICAL: OHB Integrity Failure Report ($hostname)" 
        : "OHB Integrity Alert Report ($hostname)";

    if (open(my $mail, "|-", "/usr/sbin/sendmail -t")) {
        print $mail "To: $to_list\n";
        print $mail "From: hc.fw.integrity\@$hostname\n";
        print $mail "Subject: $final_subject\n";
        print $mail "\n";
        print $mail $aggregated_alert_body;
        close($mail);
        logger("Aggregated alert email sent to $to_list");
    } else {
        logger("Error: Failed to execute sendmail: $!\n\nAGGREGATED ALERTS:\n$aggregated_alert_body", 1);
    }
}

# Helper to generate a manifest of all files and their hashes in a directory
sub get_tree_manifest {
    my ($base_dir) = @_;
    my %manifest;

    find(sub {
        return unless -f $_;
        my $rel_path = $File::Find::name;
        $rel_path =~ s/^\Q$base_dir\E\/?//;
        
        my $sha = Digest::SHA->new(256);
        $sha->addfile($_);
        $manifest{$rel_path} = $sha->hexdigest;
    }, $base_dir);

    return \%manifest;
}

# Compare two manifests
sub compare_manifests {
    my ($gh_m, $ohb_m) = @_;
    my @errors;

    # Check that every file in GH exists and matches in OHB
    foreach my $file (keys %$gh_m) {
        if (!exists $ohb_m->{$file}) {
            push @errors, "Missing file: $file";
        } elsif ($gh_m->{$file} ne $ohb_m->{$file}) {
            push @errors, "Content mismatch: $file";
        }
    }
    
    # Check for extra files in OHB
    foreach my $file (keys %$ohb_m) {
        if (!exists $gh_m->{$file}) {
            push @errors, "Extra file found: $file";
        }
    }
    
    return @errors;
}

# Helper to extract display version (e.g. 4.06.1 -> 4.06)
sub get_display_version {
    my $v = shift;
    $v =~ s/^[vV]//;
    # Matches logic in update_versions.pl: strips last field
    $v =~ s/^(\d+\.[\db]+)\..*/$1/i;
    return $v;
}

logger("Fetching release metadata from GitHub...");
my $gh_api_url = "https://api.github.com/repos/$owner/$repo/releases?per_page=50";
my $gh_resp = $ua->get($gh_api_url);
if (!$gh_resp->is_success) {
    logger("Error: Could not fetch GitHub releases: " . $gh_resp->status_line);
    exit 1;
}
my $gh_releases = decode_json($gh_resp->decoded_content);

foreach my $ohb_base_url (@ohb_servers) {
    # Ensure protocol is present for LWP
    $ohb_base_url = "https://$ohb_base_url" unless $ohb_base_url =~ /^https?:/i;

    logger("Starting firmware integrity check for $ohb_base_url");

    # 1. Determine current versions from the OHB server
    my $stable_ver_served = "";
    $ua->agent("HamClock-Verifier/1.0");
    my $s_resp = $ua->get("$ohb_base_url/ham/HamClock/version.pl");
    if ($s_resp->is_success) {
        $stable_ver_served = (split(/\R/, $s_resp->decoded_content))[0];
    } else {
        logger("  Warning: Could not reach stable version info: " . $s_resp->status_line);
        send_alert("OHB Missing Version Info", "Could not reach stable version info on $ohb_base_url\nStatus: " . $s_resp->status_line) if $alert_on_missing;
    }

    my $beta_ver_served = "";
    if ($stable_ver_served) {
        # Extract unique beta base versions from GitHub tags (e.g., 4.06 from v4.06b01)
        my %beta_bases;
        logger("  Searching for active beta tracks on $ohb_base_url...");
        foreach my $r (@$gh_releases) {
            my $tag = $r->{tag_name};
            if ($tag =~ /b/i) {
                my $tmp = $tag;
                $tmp =~ s/^[vV]//;
                if ($tmp =~ /^([\d\.]+)/) { $beta_bases{$1} = 1; }
            }
        }
        # Try beta bases in reverse order, stopping once we reach current stable
        my @sorted_beta_bases = sort { versioncmp($b, $a) } keys %beta_bases;
        foreach my $bv (@sorted_beta_bases) {
            last if versioncmp($bv, $stable_ver_served) <= 0;

            my $probe_ua = "HamClock-Verifier/${bv}b00";
            $ua->agent($probe_ua);
            my $v_resp = $ua->get("$ohb_base_url/ham/HamClock/version.pl");
            if ($v_resp->is_success) {
                my $v_line = (split(/\R/, $v_resp->decoded_content))[0];
                if ($v_line && $v_line =~ /b/i) {
                    $beta_ver_served = $v_line;
                    last;
                }
            } elsif ($v_resp->code != 404) {
                # Log unexpected errors (500s, timeouts, etc.) but ignore 404s during discovery
                logger("  Warning: Error probing beta base $bv: " . $v_resp->status_line);
            }
        }
        if (!$beta_ver_served) {
            logger("  No active beta track detected on $ohb_base_url.");
            send_alert("OHB Missing Beta Track", "No active beta track was found on $ohb_base_url. Probed various beta candidate versions but the server did not return a valid beta version string.") if $alert_on_missing;
        }
    }

    my @to_check;
    push @to_check, { type => 'stable', version => $stable_ver_served } if $stable_ver_served;
    push @to_check, { type => 'beta',   version => $beta_ver_served   } if $beta_ver_served;
    push @to_check, { type => '3.10',   version => '3.10'             } if $stable_ver_served;

    foreach my $info (@to_check) {
        my $type = $info->{type};
        my $srv_ver = $info->{version};
        logger("Checking $type release (version $srv_ver)...");

        # Set User-Agent for the request
        $ua->agent($type eq '3.10' ? "ESP8266-http-Update" : "OHB-External-Verifier/1.0");

        my $zip_filename = "ESPHamClock-V$srv_ver.zip";
        my $ohb_zip_url  = "$ohb_base_url/ham/HamClock/$zip_filename";

    # Find candidates on GitHub that share this display version (handles stripped fields)
    # For legacy 3.10, we match against the stable version tag as per update_versions.pl logic
    my $match_ver = ($type eq '3.10') ? $stable_ver_served : $srv_ver;
    my @candidates = grep { get_display_version($_->{tag_name}) eq $match_ver } @$gh_releases;
    
    if (!@candidates) {
        logger("Error: No GitHub release candidates found matching display version $srv_ver");
        next;
    }

    # Try candidates in reverse version order (newest patch first)
    @candidates = sort { versioncmp($b->{tag_name}, $a->{tag_name}) } @candidates;

    # 2. Download the ZIP from OHB and extract/revert wifi.cpp
    my $ohb_tmp_dir = tempdir(CLEANUP => 1);
    my $local_ohb_zip = "$ohb_tmp_dir/$zip_filename";
    
    logger("Downloading $zip_filename from OHB ($ohb_zip_url) and preparing for content verification...");
    my $dl_resp = $ua->get($ohb_zip_url, ':content_file' => $local_ohb_zip);
    if ($dl_resp->is_success) {
        # 3. For each GitHub candidate, download its ZIP and perform a full tree comparison
        my $matched = 0;
        my $matched_tag = "";
        my @all_errors;
        my @skip_reasons;

        foreach my $candidate (@candidates) {
            my $tag = $candidate->{tag_name};
            my ($gh_asset) = grep { $_->{name} eq $zip_filename } @{$candidate->{assets}};

            if (!$gh_asset) {
                push @skip_reasons, "$tag: Asset $zip_filename not found in GitHub release assets";
                next;
            }

            my $github_zip_url = "https://github.com/$owner/$repo/releases/download/$tag/$zip_filename";

            my $gh_tmp_dir = tempdir(CLEANUP => 1);
            my $local_gh_zip = "$gh_tmp_dir/$zip_filename";

            logger("  Trying GitHub release $tag: Downloading original $zip_filename...");
            my $gh_dl_resp = $ua->get($github_zip_url, ':content_file' => $local_gh_zip);
            if (!$gh_dl_resp->is_success) {
                my $status = $gh_dl_resp->status_line;
                logger("  Warning: Failed to download GitHub ZIP for $tag: $status");
                push @skip_reasons, "$tag: GitHub download failed ($status)";
                next; # Try next candidate
            }

            # Extract both entirely for comparison
            my $gh_extract = "$gh_tmp_dir/extract";
            my $ohb_extract = "$ohb_tmp_dir/extract";
            mkdir $gh_extract; mkdir $ohb_extract;

            system("unzip -q $local_gh_zip -d $gh_extract");
            system("unzip -q $local_ohb_zip -d $ohb_extract");

            # Normalize the OHB version (revert the patch)
            my $target_file = "ESPHamClock/wifi.cpp";
            my $ohb_wifi = "$ohb_extract/$target_file";
            if (-f $ohb_wifi) {
                system("sed -i -E 's/^(.*(DEFAULT_HOST|backend_host|software_host).* \")[^\"]*(\";?)/\\1$upstream_host\\3/' $ohb_wifi");
            }

            # Generate manifests and compare
            my $gh_manifest = get_tree_manifest($gh_extract);
            my $ohb_manifest = get_tree_manifest($ohb_extract);
            my @errors = compare_manifests($gh_manifest, $ohb_manifest);

            if (!@errors) {
                logger("SUCCESS: $zip_filename integrity verified against GitHub ($tag)");
                $matched = 1;
                $matched_tag = $tag;
                last;
            } else {
                push @all_errors, { tag => $tag, errors => \@errors };
            }
        }

        if (!$matched) {
            my $error_body = "The following discrepancies were found against all GitHub candidates for $zip_filename on $ohb_base_url:\n\n";
            
            if (@all_errors) {
                foreach my $entry (@all_errors) {
                    $error_body .= "Against $entry->{tag}:\n";
                    foreach my $err (@{$entry->{errors}}) {
                        $error_body .= "  - $err\n";
                    }
                    $error_body .= "\n";
                }
            }

            if (@skip_reasons) {
                $error_body .= "Additionally, the following candidates were skipped and could not be verified:\n";
                foreach my $reason (@skip_reasons) {
                    $error_body .= "  - $reason\n";
                }
                $error_body .= "\n";
            }

            $error_body .= "No successful comparisons were completed for this version.\n" if !@all_errors;

            logger("CRITICAL ERROR: Integrity mismatch for $zip_filename!");
            send_alert("OHB Integrity Failure: $zip_filename", $error_body);
            next; # Move to next version track
        }
    } else {
        logger("Error: Failed to download ZIP from OHB: " . $dl_resp->status_line);
        send_alert("OHB Missing File: $zip_filename", "Failed to download $zip_filename from $ohb_base_url\nStatus: " . $dl_resp->status_line) if $alert_on_missing;
    }

    # 5. Check the binary asset (.ino.bin)
    # Unlike the ZIP, the binary is not modified by the backend, so we compare hashes directly.
    # Note: Per OHB backend logic, binaries are only served for the legacy 3.10 track.
    if ($type eq '3.10') {
        my $bin_filename = "ESPHamClock-V$srv_ver.ino.bin";
        my $ohb_bin_url  = "$ohb_base_url/ham/HamClock/$bin_filename";

        # Check if the binary exists on OHB
        logger("Probing for binary asset $bin_filename...");
        my $bin_head = $ua->head($ohb_bin_url);
        if ($bin_head->is_success) {
            logger("Checking binary asset $bin_filename...");
            logger("  Found binary! Verifying integrity...");
            my $tmp_bin_dir = tempdir(CLEANUP => 1);
            my $local_ohb_bin = "$tmp_bin_dir/$bin_filename";

            my $dl_bin_resp = $ua->get($ohb_bin_url, ':content_file' => $local_ohb_bin);
            if ($dl_bin_resp->is_success) {
                my $sha = Digest::SHA->new(256);
                $sha->addfile($local_ohb_bin);
                my $actual_bin_sha = $sha->hexdigest;

                my $bin_matched = 0;
                foreach my $candidate (@candidates) {
                    # Check assets for the binary. Conventional naming on GitHub might have a prefix.
                    my ($gh_bin_asset) = grep {
                        $_->{name} eq $bin_filename ||
                        $_->{name} =~ /_\Q$bin_filename\E$/
                    } @{$candidate->{assets}};

                    if ($gh_bin_asset) {
                        my $expected_bin_sha = $gh_bin_asset->{digest} // "";
                        $expected_bin_sha =~ s/^sha256://;

                        if ($actual_bin_sha eq $expected_bin_sha) {
                            logger("SUCCESS: $bin_filename integrity verified against GitHub ($candidate->{tag_name})");
                            $bin_matched = 1;
                            last;
                        }
                    }
                }

                if (!$bin_matched) {
                    my $bin_err = "SHA256 mismatch for binary $bin_filename on $ohb_base_url\n";
                    $bin_err .= "  Actual SHA: $actual_bin_sha\n";
                    $bin_err .= "  No matching SHA found in GitHub candidates for version $srv_ver\n";
                    
                    logger("CRITICAL ERROR: $bin_err");
                    send_alert("OHB Integrity Failure: $bin_filename", $bin_err);
                    next; # Move to next version track
                }
            } else {
                logger("Warning: Failed to download binary $bin_filename from OHB: " . $dl_bin_resp->status_line);
                send_alert("OHB Missing File: $bin_filename", "Failed to download $bin_filename from $ohb_base_url\nStatus: " . $dl_bin_resp->status_line) if $alert_on_missing;
            }
        } else {
            logger("  Binary asset $bin_filename not found on server (skipping).");
            send_alert("OHB Missing File: $bin_filename", "Binary asset $bin_filename not found on $ohb_base_url") if $alert_on_missing;
        }
    }
}

logger("Integrity audit for $ohb_base_url complete.");
}

# Dispatch final aggregated report if any issues were found
dispatch_final_report();

logger("Integrity check complete.");
exit ($has_integrity_failure ? 1 : 0);

__END__

Usage:
  # Check default servers (from OHB_VERIFY_SERVERS env var), send alerts to default emails (from OHB_VERIFY_EMAILS env var), alert on missing files (default behavior)
  ./verify_firmware_integrity.pl

  # Check a specific server, send alerts to specific addresses, do not alert on missing files
  ./verify_firmware_integrity.pl -s "https://your-server-ip" -t "admin@example.com,ops@example.com" -a 0

  # Check for script updates and upgrade if available
  ./verify_firmware_integrity.pl -u

  # Override environment variables with command-line options
  OHB_VERIFY_SERVERS="https://another-server" OHB_VERIFY_EMAILS="backup@example.com" ./verify_firmware_integrity.pl -s "https://your-server-ip"
