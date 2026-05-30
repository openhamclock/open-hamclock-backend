#!/usr/bin/perl

# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use Sort::Versions;
use Digest::SHA;

# --- Configuration ---
my $owner      = "openhamclock";
my $repo       = "hamclock";
my $cache_dir  = "/opt/hamclock-backend/cache";
my $tmp_dir    = "/opt/hamclock-backend/tmp";
my $tags_url   = "https://api.github.com/repos/$owner/$repo/tags";
my $v3_ver     = "3.10";  # Hardcoded legacy version support
my $host_hostname = $ENV{'HOST_HOSTNAME'} // $ENV{'HOSTNAME'} // 'ohb.hamclock.app';

my $total_failures = 0;

mkdir $cache_dir unless -d $cache_dir;
mkdir $tmp_dir unless -d $tmp_dir;

# Increased timeout to 60s for binary downloads
my $ua = LWP::UserAgent->new(timeout => 60);
$ua->agent("Version-Cache-Updater/1.0");

# Helper for retriable file downloads
sub get_file_with_retry {
    my ($ua, $url, $path, $expected_sha) = @_;
    my $resp;
    for (my $i = 1; $i <= 3; $i++) {
        $resp = $ua->get($url, ':content_file' => $path);

        if ($resp->is_success) {
            if ($expected_sha) {
                my $clean_sha = $expected_sha;
                $clean_sha =~ s/^sha256://;
                my $sha = Digest::SHA->new(256);
                $sha->addfile($path);
                if ($sha->hexdigest eq $clean_sha) {
                    return $resp;
                }
                print "  Warning: SHA256 mismatch for $url on attempt $i. Retrying...\n";
                unlink $path;
            } else {
                return $resp;
            }
        } else {
            print "  Warning: Attempt $i to download $url failed: " . $resp->status_line . "\n";
            unlink $path if -f $path;
            last if $resp->code == 404;
        }
        sleep(2 * $i) if $i < 3;
    }
    # If SHA mismatch happened on final attempt, ensure response indicates failure
    if ($resp->is_success && $expected_sha && !-f $path) {
        $resp->code(500);
        $resp->message("SHA256 mismatch after retries");
    }
    return $resp;
}

# Helper to verify SHA256 and cleanup on failure
sub verify_and_cleanup {
    my ($file_path, $expected_sha, $associated_files) = @_;
    return 1 unless -f $file_path;

    if (!$expected_sha) {
        print "Warning: No SHA256 provided for $file_path. Skipping verification.\n";
        return 1;
    }

    # Clean the SHA (strip "sha256:" prefix if present)
    $expected_sha =~ s/^sha256://;

    # Save the sha256sum file locally
    my $sha_local_path = "$file_path.sha256";
    if (open(my $sfh, '>', $sha_local_path)) {
        my $filename = (split(/\//, $file_path))[-1];
        print $sfh "$expected_sha  $filename\n";
        close($sfh);
        chmod 0644, $sha_local_path;
    }

    my $sha = Digest::SHA->new(256);
    $sha->addfile($file_path);
    my $actual_sha = $sha->hexdigest;

    if ($actual_sha eq $expected_sha) {
        return 1;
    } else {
        print "Error: SHA256 mismatch for $file_path! Deleting artifacts.\n";
        unlink $file_path;
        unlink $sha_local_path;
        foreach my $f (@$associated_files) {
            unlink $f if -f $f;
        }
        return 0;
    }
}

# 1. Fetch Tags from GitHub
my $tags_resp = $ua->get($tags_url);
die "GitHub API Error: " . $tags_resp->status_line unless $tags_resp->is_success;

my $tags_data = decode_json($tags_resp->decoded_content);

my $tags = [];
foreach my $t (@$tags_data) {
    my $original = $t->{name};
    my $clean = $original;
    $clean =~ s/^[vV]//; # Strip v/V for sorting purposes
    push @$tags, { clean => $clean, original => $original };
}

my ($stable_tag, $beta_tag);
foreach my $tag (@$tags) {
    if (!$stable_tag && $tag->{clean} !~ /b/i) {
        $stable_tag = $tag;
    }
    if (!$beta_tag && $tag->{clean} =~ /b/i) {
        $beta_tag = $tag;
    }
    last if $stable_tag && $beta_tag;
}

# 2. Process and Save to .txt, .tag, and .zip files
foreach my $item (
    { type => 'stable', data => $stable_tag },
    { type => 'beta',   data => $beta_tag   },
    { type => $v3_ver,  data => $stable_tag }
) {
    my $base_name = "$cache_dir/HC_RELEASE-" . $item->{type};
    my $txt_file  = "$base_name.txt";
    my $tag_file  = "$base_name.tag";

    if (!$item->{data}) {
        print "No version found for $item->{type}\n";
        next;
    }

    my $clean_ver = $item->{data}->{clean};
    my $orig_ver  = $item->{data}->{original};
    my $display_version = ($item->{type} eq $v3_ver) ? $v3_ver : $clean_ver;
    $display_version =~ s/^(\d+\.[\db]+)\..*/$1/i;

    # Fetch Release Metadata early for Change Detection
    my $rel_url = "https://api.github.com/repos/$owner/$repo/releases/tags/$orig_ver";
    my $rel_resp = $ua->get($rel_url);
    my $rel_data = $rel_resp->is_success ? decode_json($rel_resp->decoded_content) : undef;

    # Define the target ZIP and its local SHA file
    my $zip_filename = "ESPHamClock-V$display_version.zip";
    my $zip_path     = "$cache_dir/$zip_filename";
    my $zip_sha_path = "$zip_path.sha256";

    # Get the current digest from the API
    my ($zip_asset) = $rel_data ? grep { $_->{name} eq $zip_filename } @{$rel_data->{assets}} : ();
    my $zip_digest = ($zip_asset->{digest} // "");
    $zip_digest =~ s/^sha256://;

    # --- Change Detection Logic (SHA Comparison) ---
    if ($zip_digest && -f $zip_sha_path) {
        if (open(my $sfh, '<', $zip_sha_path)) {
            my $line = <$sfh>;
            close($sfh);
            if ($line) {
                my $existing_sha = (split(/\s+/, $line))[0];
                if ($existing_sha eq $zip_digest) {
                    print "Skipping $item->{type}: SHA256 $zip_digest matches local cache.\n";
                    next;
                }
            }
        }
    }

    # --- If we are here, an update is needed ---

    # 1. Download the Release Asset ZIP
    my $zip_url = "https://github.com/$owner/$repo/releases/download/$orig_ver/$zip_filename";

    print "Update found! Downloading $item->{type} asset from $zip_url...\n";
    my $zip_resp = get_file_with_retry($ua, $zip_url, $zip_path, $zip_digest);

    if ($zip_resp->is_success) {
        chmod 0644, $zip_path;
        unless (verify_and_cleanup($zip_path, $zip_digest, [$txt_file, $tag_file])) {
            $total_failures++;
            next;
        }
        print "Successfully saved and verified $zip_path\n";

        # Delete prior betas if this is a new beta
        if ($item->{type} eq 'beta') {
            foreach my $old_beta (glob("$cache_dir/ESPHamClock-V*b*.zip")) {
                next if $old_beta eq $zip_path;
                unlink $old_beta;
                unlink "$old_beta.sha256";
            }
        }

        # Update wifi.cpp inside zip
        my $target_file = "ESPHamClock/wifi.cpp";
        system("unzip -q -o $zip_path $target_file -d $tmp_dir");
        if (-f "$tmp_dir/$target_file") {
            # depending on the version, the backend host could be in DEFAULT_HOST or backend_host. Also software_host
            # might be used
            system("sed -i -E 's/^(.*(DEFAULT_HOST|backend_host|software_host).* \")[^\"]*(\";?)/\\1$host_hostname\\3/' $tmp_dir/$target_file");
            system("cd $tmp_dir && zip -q -u $zip_path $target_file");
            system("rm -rf $tmp_dir/ESPHamClock");
        }
    } else {
        print "Error: Failed to download $zip_filename. Status: " . $zip_resp->status_line . "\n";
        $total_failures++ if $zip_resp->code != 404;
        next;
    }

    # 1b. Additionally download the .ino.bin if this is the v3_ver (3.10)
    if ($item->{type} eq $v3_ver) {
        my $bin_filename = "ESPHamClock-V$display_version.ino.bin";
        my $bin_path     = "$cache_dir/$bin_filename";
        my $bin_url      = "https://github.com/$owner/$repo/releases/download/$orig_ver/${host_hostname}_${bin_filename}";

        my ($bin_asset) = $rel_data ? grep { $_->{name} eq "${host_hostname}_${bin_filename}" } @{$rel_data->{assets}} : ();
        my $bin_digest = $bin_asset->{digest} // "";

        print "Downloading additional binary asset from $bin_url...\n";
        my $bin_resp = get_file_with_retry($ua, $bin_url, $bin_path, $bin_digest);
        if ($bin_resp->is_success) {
            chmod 0644, $bin_path;
            unless (verify_and_cleanup($bin_path, $bin_digest, [$txt_file, $tag_file, $zip_path, $zip_sha_path])) {
                $total_failures++;
            }
        } else {
            print "Error: Failed to download $bin_filename. Status: " . $bin_resp->status_line . "\n";
            $total_failures++ if $bin_resp->code != 404;
        }
    }

    # 2. Write the .tag file
    open(my $tfh, '>', $tag_file) or next;
    print $tfh $orig_ver . "\n";
    close($tfh);
    chmod 0644, $tag_file;

    # 3. Fetch HC_RELEASE-*.txt content
    my $github_txt = "HC_RELEASE-" . $item->{type} . ".txt";
    my $raw_url = "https://raw.githubusercontent.com/$owner/$repo/$orig_ver/$github_txt";
    my $resp = $ua->get($raw_url);

    open(my $fh, '>', $txt_file) or next;
    print $fh $display_version . "\n";

    my $status_msg = "Fetched $orig_ver for $item->{type}";
    if ($resp->is_success && $resp->decoded_content =~ /\S/) {
        print $fh $resp->decoded_content;
        $status_msg .= " (with release notes)";
    } else {
        print $fh "No info for version " . $display_version . "\n";
        $status_msg .= " (no release notes found)";
    }

    close($fh);
    chmod 0644, $txt_file;
    print "Success: Processed $item->{type} -> $status_msg\n";
}

# --- Handle main branch zip ---
my $main_sha_url = "https://api.github.com/repos/$owner/$repo/commits/main";
my $main_zip_url = "https://github.com/$owner/$repo/archive/refs/heads/main.zip";
my $main_zip_name = "ESPHamClock-main.zip";
my $main_zip_path = "$cache_dir/$main_zip_name";
my $main_sha_path = "$main_zip_path.sha";

my $sha_resp = $ua->get($main_sha_url, 'Accept' => 'application/vnd.github.sha');
if ($sha_resp->is_success) {
    my $current_sha = $sha_resp->decoded_content;
    chomp($current_sha);

    my $old_sha = "";
    if (-f $main_sha_path) {
        open(my $shafh, '<', $main_sha_path);
        $old_sha = <$shafh>;
        close($shafh);
        chomp($old_sha) if $old_sha;
    }

    if ($current_sha ne $old_sha || !-f $main_zip_path) {
        print "Main branch update found (SHA: $current_sha). Downloading...\n";
        my $zip_resp = get_file_with_retry($ua, $main_zip_url, $main_zip_path);

        if ($zip_resp->is_success) {
            # Extract only the ESPHamClock folder from the main repo zip
            my $repo_root = "hamclock-main";
            my $target_folder = "ESPHamClock";

            # Extract only the source folder from the main repo zip
            system("unzip -q -o $main_zip_path '$repo_root/$target_folder/*' -d $tmp_dir");

            # Patch wifi.cpp in the extracted folder
            my $target_file = "$tmp_dir/$repo_root/$target_folder/wifi.cpp";
            if (-f $target_file) {
                system("sed -i -E 's/^(.*(DEFAULT_HOST|backend_host|software_host).* \")[^\"]*(\";?)/\\1$host_hostname\\3/' $target_file");
            }

            # Re-zip just the ESPHamClock folder (stripped of hamclock-main prefix)
            system("rm -f $main_zip_path");
            system("cd $tmp_dir/$repo_root && zip -q -r $main_zip_path $target_folder");

            # Cleanup and save SHA
            system("rm -rf $tmp_dir/$repo_root");
            open(my $shafh, '>', $main_sha_path);
            print $shafh $current_sha;
            close($shafh);
            chmod 0644, $main_zip_path;
            print "Success: Processed main branch into ESPHamClock-only zip\n";
        } else {
            print "Error: Failed to download $main_zip_name. Status: " . $zip_resp->status_line . "\n";
            $total_failures++ if $zip_resp->code != 404;
        }
    } else {
        print "Main branch is up to date.\n";
    }
}

exit($total_failures);
