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
use FindBin;
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

# --- Cache Initialization ---
my $cache_dir = "$FindBin::Bin/cache";
my $use_cache = 1;
if (!-d $cache_dir) {
    if (!mkdir($cache_dir, 0755)) {
        logger("Warning: Could not create cache directory '$cache_dir': $!. Running without cache.");
        $use_cache = 0;
    }
} elsif (!-w $cache_dir) {
    logger("Warning: Cache directory '$cache_dir' is not writable. Running without cache.");
    $use_cache = 0;
}

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

            my $expected_sha = ($asset->{digest} // "") =~ s/^sha256://r;
            my ($success, $error) = download_with_retry($asset->{browser_download_url}, $0, $expected_sha, "Upgrade:");
            if ($success) {
                logger("Upgrade successful. Script replaced at $0. Please restart.", 1);
                exit 0;
            } else {
                logger("Error downloading upgrade: $error", 1);
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

# Helper to download a file with retries and SHA256 verification
sub download_with_retry {
    my ($url, $dest, $expected_sha, $log_prefix) = @_;
    my $max_attempts = 3;
    my $delay = 10;

    # Check if file exists and matches SHA before attempting download
    if (-f $dest && defined $expected_sha && $expected_sha ne "") {
        my $actual_sha = eval {
            my $sha = Digest::SHA->new(256);
            $sha->addfile($dest);
            $sha->hexdigest;
        };
        return (1, "") if (!$@ && defined $actual_sha && $actual_sha eq $expected_sha);
    }

    my $last_error = "";

    for (my $attempt = 1; $attempt <= $max_attempts; $attempt++) {
        if ($attempt > 1) {
            logger("$log_prefix Retrying download (attempt $attempt/$max_attempts)...");
            sleep($delay);
        }

        # Clear previous partial download if it exists
        unlink($dest) if -f $dest;

        my $resp = $ua->get($url, ':content_file' => $dest);

        if ($resp->is_success) {
            if (defined $expected_sha && $expected_sha ne "") {
                my $actual_sha;
                eval {
                    my $sha = Digest::SHA->new(256);
                    $sha->addfile($dest);
                    $actual_sha = $sha->hexdigest;
                };
                if ($@) {
                    $last_error = "Hashing failed: $@";
                } elsif ($actual_sha eq $expected_sha) {
                    # Save the sha256sum file locally
                    my $sha_local_path = "$dest.sha256";
                    if (open(my $sfh, '>', $sha_local_path)) {
                        my $filename = (split(/\//, $dest))[-1];
                        print $sfh "$expected_sha  $filename\n";
                        close($sfh);
                        chmod 0644, $sha_local_path;
                    }

                    return (1, ""); # Success
                } else {
                    $last_error = "SHA256 mismatch: expected $expected_sha, got $actual_sha";
                }
            } else {
                return (1, ""); # Success (no hash provided to check)
            }
        } else {
            $last_error = "HTTP error: " . $resp->status_line;
        }
        logger("$log_prefix $last_error") if $last_error;
    }

    return (0, $last_error);
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

    my $url_log = "[$ohb_base_url]";
    logger("$url_log Starting firmware integrity audit...");

    # 1. Determine current versions from the OHB server
    my $stable_ver_served = "";
    $ua->agent("HamClock-Verifier/1.0");
    my $s_resp = $ua->get("$ohb_base_url/ham/HamClock/version.pl");
    if ($s_resp->is_success) {
        $stable_ver_served = (split(/\R/, $s_resp->decoded_content))[0];
    } else {
        logger("$url_log Warning: Could not reach stable version info: " . $s_resp->status_line);
        send_alert("$url_log Missing Version Info", "Could not reach version.pl on $ohb_base_url\nStatus: " . $s_resp->status_line) if $alert_on_missing;
    }

    my $beta_ver_served = "";
    if ($stable_ver_served) {
        # Extract unique beta base versions from GitHub tags (e.g., 4.06 from v4.06b01)
        my %beta_bases;
        logger("$url_log Searching for active beta tracks...");
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
        my $github_has_newer_beta = 0;
        foreach my $bv (@sorted_beta_bases) {
            last if versioncmp($bv, $stable_ver_served) <= 0;
            $github_has_newer_beta = 1;

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
                logger("$url_log Warning: Error probing beta base $bv: " . $v_resp->status_line);
            }
        }
        if (!$beta_ver_served && $github_has_newer_beta) {
            logger("$url_log No active beta track detected.");
            send_alert("$url_log Missing Beta Track", "GitHub has a newer beta version available, but no active beta track was found on $ohb_base_url. Probed various beta candidate versions but the server did not return a valid beta version string.") if $alert_on_missing;
        } elsif (!$beta_ver_served) {
            logger("$url_log No new beta track available on GitHub (relative to stable $stable_ver_served).");
        }
    }

    my @to_check;
    push @to_check, { type => 'stable', version => $stable_ver_served } if $stable_ver_served;
    push @to_check, { type => 'beta',   version => $beta_ver_served   } if $beta_ver_served;
    push @to_check, { type => '3.10',   version => '3.10'             } if $stable_ver_served;

    foreach my $info (@to_check) {
        my $type = $info->{type};
        my $srv_ver = $info->{version};

        my $track_log = "$url_log [$type track v$srv_ver]";
        logger("$track_log Verifying assets...");

        # 1. Set User-Agent for this track
        if ($type eq '3.10') {
            $ua->agent("ESP8266-http-Update");
        } elsif ($type eq 'beta') {
            $ua->agent("HamClock-Verifier/$srv_ver");
        } else {
            $ua->agent("OHB-External-Verifier/1.0");
        }

        my $zip_filename = "ESPHamClock-V$srv_ver.zip";
        my $ohb_zip_url  = "$ohb_base_url/ham/HamClock/$zip_filename";

        # 2. Identify GitHub candidates for this version
        my $match_ver = ($type eq '3.10') ? $stable_ver_served : $srv_ver;
        my @candidates = grep { get_display_version($_->{tag_name}) eq $match_ver } @$gh_releases;
        @candidates = sort { versioncmp($b->{tag_name}, $a->{tag_name}) } @candidates;

        if (!@candidates) {
            logger("$track_log Error: No GitHub release candidates found matching version $srv_ver");
        }

        # 3. Verify versioned ZIP against GitHub
        my $ohb_tmp_dir = tempdir(CLEANUP => 1);
        my $local_ohb_zip = "$ohb_tmp_dir/$zip_filename";

        logger("$track_log Downloading $zip_filename for source verification...");
        my $dl_resp = $ua->get($ohb_zip_url, ':content_file' => $local_ohb_zip);
        if ($dl_resp->is_success) {
            my $matched = 0;
            my @all_errors;
            my @skip_reasons;

            foreach my $candidate (@candidates) {
                my $tag = $candidate->{tag_name};
                my ($gh_asset) = grep { $_->{name} eq $zip_filename } @{$candidate->{assets}};
                if (!$gh_asset) {
                    push @skip_reasons, "$tag: Asset $zip_filename not found in GitHub release";
                    next;
                }

                my $github_zip_url = "https://github.com/$owner/$repo/releases/download/$tag/$zip_filename";
                my $gh_tmp_dir = tempdir(CLEANUP => 1); # for extraction
                my $local_gh_zip = $use_cache ? "$cache_dir/$tag-$zip_filename" : "$gh_tmp_dir/$zip_filename";

                logger("$track_log   Comparing content against GitHub release $tag...");
                my $expected_sha = ($gh_asset->{digest} // "") =~ s/^sha256://r;
                my ($success, $error) = download_with_retry($github_zip_url, $local_gh_zip, $expected_sha, "$track_log $tag:");
                if (!$success) {
                    push @skip_reasons, "$tag: GitHub download failed ($error)";
                    next;
                }

                my $gh_extract = "$gh_tmp_dir/extract";
                my $ohb_extract = "$ohb_tmp_dir/extract";
                mkdir $gh_extract; mkdir $ohb_extract;
                system("unzip -q $local_gh_zip -d $gh_extract");
                system("unzip -q $local_ohb_zip -d $ohb_extract");

                my $target_file = "ESPHamClock/wifi.cpp";
                my $ohb_wifi = "$ohb_extract/$target_file";
                if (-f $ohb_wifi) {
                    system("sed -i -E 's/^(.*(DEFAULT_HOST|backend_host|software_host).* \")[^\"]*(\";?)/\\1$upstream_host\\3/' $ohb_wifi");
                }

                my @errors = compare_manifests(get_tree_manifest($gh_extract), get_tree_manifest($ohb_extract));
                if (!@errors) {
                    logger("$track_log   SUCCESS: $zip_filename verified against GitHub ($tag)");
                    $matched = 1;
                    last;
                } else {
                    push @all_errors, { tag => $tag, errors => \@errors };
                }
            }

            if (!$matched) {
                my $error_body = "Server: $ohb_base_url\nTrack: $type\nFile: $zip_filename\n\nDiscrepancies against GitHub candidates:\n";
                foreach my $entry (@all_errors) {
                    $error_body .= "Against $entry->{tag}:\n" . join("", map { "  - $_\n" } @{$entry->{errors}}) . "\n";
                }
                foreach my $reason (@skip_reasons) { $error_body .= "  - $reason (skipped)\n"; }
                logger("$track_log CRITICAL ERROR: Source mismatch for $zip_filename!");
                send_alert("$track_log Source Integrity Failure", $error_body);
            }
        } else {
            logger("$track_log Error: Failed to download $zip_filename: " . $dl_resp->status_line);
            send_alert("$track_log Missing File", "Failed to download $zip_filename from $ohb_base_url") if $alert_on_missing;
        }

        # 4. Verify generic ZIP matches versioned ZIP (Skip 3.10)
        if ($type ne '3.10') {
            my $generic_zip = "ESPHamClock.zip";
            my $ohb_generic_url = "$ohb_base_url/ham/HamClock/$generic_zip";
            logger("$track_log Verifying generic asset $generic_zip matches $zip_filename...");
            my $local_ohb_generic = "$ohb_tmp_dir/$generic_zip";
            my $gen_resp = $ua->get($ohb_generic_url, ':content_file' => $local_ohb_generic);
            if ($gen_resp->is_success && -f $local_ohb_zip) {
                if (Digest::SHA->new(256)->addfile($local_ohb_zip)->hexdigest eq Digest::SHA->new(256)->addfile($local_ohb_generic)->hexdigest) {
                    logger("$track_log   SUCCESS: Generic $generic_zip is correct.");
                } else {
                    my $msg = "Generic asset $generic_zip does NOT match $zip_filename on $ohb_base_url.\n";
                    $msg .= "This usually indicates the 'latest' link is pointing to the wrong version for the $type track.";
                    logger("$track_log   CRITICAL ERROR: $generic_zip mismatch!");
                    send_alert("$track_log Generic Asset Mismatch", $msg);
                }
            } elsif (!$gen_resp->is_success) {
                logger("$track_log   Warning: Could not fetch generic $generic_zip: " . $gen_resp->status_line);
            }
        }

        # 5. Check the binary asset (.ino.bin) (3.10 track only)
        if ($type eq '3.10') {
            my $bin_filename = "ESPHamClock-V$srv_ver.ino.bin";
            my $ohb_bin_url  = "$ohb_base_url/ham/HamClock/$bin_filename";
            my $local_ohb_bin = "$ohb_tmp_dir/$bin_filename";

            logger("$track_log Probing for binary asset $bin_filename...");
            my $dl_bin_resp = $ua->get($ohb_bin_url, ':content_file' => $local_ohb_bin);
            if ($dl_bin_resp->is_success) {
                my $actual_bin_sha = Digest::SHA->new(256)->addfile($local_ohb_bin)->hexdigest;
                my $bin_matched = 0;
                foreach my $candidate (@candidates) {
                    my ($gh_bin_asset) = grep { $_->{name} eq $bin_filename || $_->{name} =~ /_\Q$bin_filename\E$/ } @{$candidate->{assets}};
                    if ($gh_bin_asset) {
                        my $expected_bin_sha = ($gh_bin_asset->{digest} // "") =~ s/^sha256://r;
                        if ($actual_bin_sha eq $expected_bin_sha) {
                            logger("$track_log   SUCCESS: $bin_filename verified against GitHub ($candidate->{tag_name})");
                            $bin_matched = 1; last;
                        }
                    }
                }
                if (!$bin_matched) {
                    my $bin_err = "Server: $ohb_base_url\nBinary: $bin_filename\nActual SHA: $actual_bin_sha\nNo matching candidate found on GitHub.";
                    logger("$track_log   CRITICAL ERROR: Binary source mismatch!");
                    send_alert("$track_log Binary Source Mismatch", $bin_err);
                }

                # Verify generic binary against versioned binary
                my $generic_bin = "ESPHamClock.ino.bin";
                my $ohb_generic_bin_url = "$ohb_base_url/ham/HamClock/$generic_bin";
                logger("$track_log Verifying generic asset $generic_bin matches $bin_filename...");
                my $local_ohb_generic_bin = "$ohb_tmp_dir/$generic_bin";
                my $gen_bin_resp = $ua->get($ohb_generic_bin_url, ':content_file' => $local_ohb_generic_bin);
                if ($gen_bin_resp->is_success) {
                    if (Digest::SHA->new(256)->addfile($local_ohb_bin)->hexdigest eq Digest::SHA->new(256)->addfile($local_ohb_generic_bin)->hexdigest) {
                        logger("$track_log   SUCCESS: Generic $generic_bin is correct.");
                    } else {
                        my $msg = "Generic asset $generic_bin does NOT match $bin_filename on $ohb_base_url.\n";
                        $msg .= "The ESP8266 automated update will fail to find the correct binary.";
                        logger("$track_log   CRITICAL ERROR: $generic_bin mismatch!");
                        send_alert("$track_log Generic Binary Mismatch", $msg);
                    }
                } else {
                    logger("$track_log   Warning: Could not fetch generic $generic_bin: " . $gen_bin_resp->status_line);
                }
            } else {
                logger("$track_log Warning: Binary asset $bin_filename not found or failed download.");
                send_alert("$track_log Missing Binary", "Failed to download $bin_filename from $ohb_base_url") if $alert_on_missing;
            }
        }
    } # End track loop

    logger("$url_log Integrity audit complete.");
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
