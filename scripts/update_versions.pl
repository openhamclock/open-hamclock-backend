#!/usr/bin/perl
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

mkdir $cache_dir unless -d $cache_dir;
mkdir $tmp_dir unless -d $tmp_dir;

# Increased timeout to 60s for binary downloads
my $ua = LWP::UserAgent->new(timeout => 60);
$ua->agent("Version-Cache-Updater/1.0");

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
    my $zip_resp = $ua->get($zip_url, ':content_file' => $zip_path);

    if ($zip_resp->is_success) {
        chmod 0644, $zip_path;
        unless (verify_and_cleanup($zip_path, $zip_digest, [$txt_file, $tag_file])) {
            next;
        }
        print "Successfully saved and verified $zip_path\n";

        # Update wifi.cpp inside zip
        my $target_file = "ESPHamClock/wifi.cpp";
        system("unzip -q -o $zip_path $target_file -d $tmp_dir");
		if (-f "$tmp_dir/$target_file") {
            # depending on the version, the backend host could be in DEFAULT_HOST or backend_host. Also software_host
            # might be used
            system("sed -i -E 's/^(.*(DEFAULT_HOST|backend_host|software_host).* \")[^\"]*(\";?)/\\1$host_hostname\\3/' $tmp_dir/$target_file");
            system("cd $tmp_dir && zip -q -u $zip_path $target_file");
            system("rm -rf $tmp_dir/ESPHamClock");

            # Update local SHA file to match modified zip
            my $new_sha = Digest::SHA->new(256)->addfile($zip_path)->hexdigest;
            if (open(my $sfh, '>', $zip_sha_path)) {
                print $sfh "$new_sha  $zip_filename\n";
                close($sfh);
            }
        }
    } else {
        print "Error: Failed to download $zip_filename. Status: " . $zip_resp->status_line . "\n";
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
        my $bin_resp = $ua->get($bin_url, ':content_file' => $bin_path);
        if ($bin_resp->is_success) {
            chmod 0644, $bin_path;
            verify_and_cleanup($bin_path, $bin_digest, [$txt_file, $tag_file, $zip_path, $zip_sha_path]);
        } else {
            print "Error: Failed to download $bin_filename.\n";
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
