package Git::SVN::Fetcher;
use vars qw/@ISA $_ignore_regex $_include_regex $_preserve_empty_dirs
            $_placeholder_filename @deleted_gpath %added_placeholder
            $repo_id/;
use strict;
use warnings $ENV{GIT_PERL_FATAL_WARNINGS} ? qw(FATAL all) : ();
use SVN::Delta;
use Carp qw/croak/;
use File::Basename qw/dirname/;
use Git qw/command command_oneline command_noisy command_output_pipe
           command_input_pipe command_close_pipe
           command_bidi_pipe command_close_bidi_pipe
           get_record/;
BEGIN {
	@ISA = qw(SVN::Delta::Editor);
}

# file baton members: path, mode_a, mode_b, pool, fh, blob, base
sub new {
	my ($class, $git_svn, $switch_path) = @_;
	my $self = SVN::Delta::Editor->new;
	bless $self, $class;
	if (exists $git_svn->{last_commit}) {
		$self->{c} = $git_svn->{last_commit};
		$self->{empty_symlinks} =
		                  _mark_empty_symlinks($git_svn, $switch_path);
	}

	# some options are read globally, but can be overridden locally
	# per [svn-remote "..."] section.  Command-line options will *NOT*
	# override options set in an [svn-remote "..."] section
	$repo_id = $git_svn->{repo_id};
	my $k = "svn-remote.$repo_id.ignore-paths";
	my $v = eval { command_oneline('config', '--get', $k) };
	$self->{ignore_regex} = $v;

	$k = "svn-remote.$repo_id.include-paths";
	$v = eval { command_oneline('config', '--get', $k) };
	$self->{include_regex} = $v;

	$k = "svn-remote.$repo_id.preserve-empty-dirs";
	$v = eval { command_oneline('config', '--get', '--bool', $k) };
	if ($v && $v eq 'true') {
		$_preserve_empty_dirs = 1;
		$k = "svn-remote.$repo_id.placeholder-filename";
		$v = eval { command_oneline('config', '--get', $k) };
		$_placeholder_filename = $v;
	}

	# Load the list of placeholder files added during previous invocations.
	$k = "svn-remote.$repo_id.added-placeholder";
	$v = eval { command_oneline('config', '--get-all', $k) };
	if ($_preserve_empty_dirs && $v) {
		# command() prints errors to stderr, so we only call it if
		# command_oneline() succeeded.
		my @v = command('config', '--get-all', $k);
		$added_placeholder{ dirname($_) } = $_ foreach @v;
	}

	$self->{empty} = {};
	$self->{dir_prop} = {};
	$self->{file_prop} = {};
	$self->{absent_dir} = {};
	$self->{absent_file} = {};
	require Git::IndexInfo;
	$self->{gii} = $git_svn->tmp_index_do(sub { Git::IndexInfo->new });
	$self->{pathnameencoding} = Git::config('svn.pathnameencoding');
	$self;
}

# this uses the Ra object, so it must be called before do_{switch,update},
# not inside them (when the Git::SVN::Fetcher object is passed) to
# do_{switch,update}
sub _mark_empty_symlinks {
	my ($git_svn, $switch_path) = @_;
	my $bool = Git::config_bool('svn.brokenSymlinkWorkaround');
	return {} if (!defined($bool)) || (defined($bool) && ! $bool);

	my %ret;
	my ($rev, $cmt) = $git_svn->last_rev_commit;
	return {} unless ($rev && $cmt);

	# allow the warning to be printed for each revision we fetch to
	# ensure the user sees it.  The user can also disable the workaround
	# on the repository even while git svn is running and the next
	# revision fetched will skip this expensive function.
	my $printed_warning;
	chomp(my $empty_blob = `git hash-object -t blob --stdin < /dev/null`);
	my ($ls, $ctx) = command_output_pipe(qw/ls-tree -r -z/, $cmt);
	my $pfx = defined($switch_path) ? $switch_path : $git_svn->path;
	$pfx .= '/' if length($pfx);
	while (defined($_ = get_record($ls, "\0"))) {
		s/\A100644 blob $empty_blob\t//o or next;
		unless ($printed_warning) {
			print STDERR "Scanning for empty symlinks, ",
			             "this may take a while if you have ",
				     "many empty files\n",
				     "You may disable this with `",
				     "git config svn.brokenSymlinkWorkaround ",
				     "false'.\n",
				     "This may be done in a different ",
				     "terminal without restarting ",
				     "git svn\n";
			$printed_warning = 1;
		}
		my $path = $_;
		my (undef, $props) =
		               $git_svn->ra->get_file($pfx.$path, $rev, undef);
		if ($props->{'svn:special'}) {
			$ret{$path} = 1;
		}
	}
	command_close_pipe($ls, $ctx);
	\%ret;
}

# returns true if a given path is inside a ".git" directory
sub in_dot_git {
	$_[0] =~ m{(?:^|/)\.git(?:/|$)};
}

# return value: 0 -- don't ignore, 1 -- ignore
# This will also check whether the path is explicitly included
sub is_path_ignored {
	my ($self, $path) = @_;
	return 1 if in_dot_git($path);
	return 1 if defined($self->{ignore_regex}) &&
	            $path =~ m!$self->{ignore_regex}!;
	return 0 if defined($self->{include_regex}) &&
	            $path =~ m!$self->{include_regex}!;
	return 0 if defined($_include_regex) &&
	            $path =~ m!$_include_regex!;
	return 1 if defined($self->{include_regex});
	return 1 if defined($_include_regex);
	return 0 unless defined($_ignore_regex);
	return 1 if $path =~ m!$_ignore_regex!o;
	return 0;
}

sub set_path_strip {
	my ($self, $path) = @_;
	$self->{path_strip} = qr/^\Q$path\E(\/|$)/ if length $path;
}

sub open_root {
	{ path => '' };
}

sub open_directory {
	my ($self, $path, $pb, $rev) = @_;
	{ path => $path };
}

sub git_path {
	my ($self, $path) = @_;
	if (my $enc = $self->{pathnameencoding}) {
		require Encode;
		Encode::from_to($path, 'UTF-8', $enc);
	}
	if ($self->{path_strip}) {
		$path =~ s!$self->{path_strip}!! or
		  die "Failed to strip path '$path' ($self->{path_strip})\n";
	}
	$path;
}

sub delete_entry {
	my ($self, $path, $rev, $pb) = @_;
	return undef if $self->is_path_ignored($path);

	my $gpath = $self->git_path($path);
	return undef if ($gpath eq '');

	# remove entire directories.
	my ($tree) = (command('ls-tree', '-z', $self->{c}, "./$gpath")
	                 =~ /\A040000 tree ($::oid)\t\Q$gpath\E\0/);
	if ($tree) {
		my ($ls, $ctx) = command_output_pipe(qw/ls-tree
		                                     -r --name-only -z/,
				                     $tree);
		while (defined($_ = get_record($ls, "\0"))) {
			my $rmpath = "$gpath/$_";
			$self->{gii}->remove($rmpath);
			print "\tD\t$rmpath\n" unless $::_q;
		}
		print "\tD\t$gpath/\n" unless $::_q;
		command_close_pipe($ls, $ctx);
	} else {
		$self->{gii}->remove($gpath);
		print "\tD\t$gpath\n" unless $::_q;
	}
	# Don't add to @deleted_gpath if we're deleting a placeholder file.
	push @deleted_gpath, $gpath unless $added_placeholder{dirname($path)};
	$self->{empty}->{$path} = 0;
	undef;
}

sub open_file {
	my ($self, $path, $pb, $rev) = @_;
	my ($mode, $blob);

	goto out if $self->is_path_ignored($path);

	my $gpath = $self->git_path($path);
	($mode, $blob) = (command('ls-tree', '-z', $self->{c}, "./$gpath")
	                     =~ /\A(\d{6}) blob ($::oid)\t\Q$gpath\E\0/);
	unless (defined $mode && defined $blob) {
		die "$path was not found in commit $self->{c} (r$rev)\n";
	}
	if ($mode eq '100644' && $self->{empty_symlinks}->{$path}) {
		$mode = '120000';
	}
out:
	{ path => $path, mode_a => $mode, mode_b => $mode, blob => $blob,
	  pool => SVN::Pool->new, action => 'M' };
}

sub add_file {
	my ($self, $path, $pb, $cp_path, $cp_rev) = @_;
	my $mode;

	if (!$self->is_path_ignored($path)) {
		my ($dir, $file) = ($path =~ m#^(.*?)/?([^/]+)$#);
		delete $self->{empty}->{$dir};
		$mode = '100644';

		if ($added_placeholder{$dir}) {
			# Remove our placeholder file, if we created one.
			delete_entry($self, $added_placeholder{$dir})
				unless $path eq $added_placeholder{$dir};
			delete $added_placeholder{$dir}
		}
	}

	{ path => $path, mode_a => $mode, mode_b => $mode,
	  pool => SVN::Pool->new, action => 'A' };
}

sub add_directory {
	my ($self, $path, $cp_path, $cp_rev) = @_;
	goto out if $self->is_path_ignored($path);
	my $gpath = $self->git_path($path);
	if ($gpath eq '') {
		my ($ls, $ctx) = command_output_pipe(qw/ls-tree
		                                     -r --name-only -z/,
				                     $self->{c});
		while (defined($_ = get_record($ls, "\0"))) {
			$self->{gii}->remove($_);
			print "\tD\t$_\n" unless $::_q;
			push @deleted_gpath, $gpath;
		}
		command_close_pipe($ls, $ctx);
		$self->{empty}->{$path} = 0;
	}
	my ($dir, $file) = ($path =~ m#^(.*?)/?([^/]+)$#);
	delete $self->{empty}->{$dir};
	$self->{empty}->{$path} = 1;

	if ($added_placeholder{$dir}) {
		# Remove our placeholder file, if we created one.
		delete_entry($self, $added_placeholder{$dir});
		delete $added_placeholder{$dir}
	}

out:
	{ path => $path };
}

sub change_dir_prop {
	my ($self, $db, $prop, $value) = @_;
	return undef if $self->is_path_ignored($db->{path});
	
	# Cache the properties safely in a temporary list array to evaluate during the finalize cycle
	if ($prop eq 'svn:externals' && defined $value) {
		push @{$self->{_pending_externals}}, { path => $db->{path}, value => $value };
	}

	$self->{dir_prop}->{$db->{path}} ||= {};
	$self->{dir_prop}->{$db->{path}}->{$prop} = $value;
	undef;
}


sub absent_directory {
	my ($self, $path, $pb) = @_;
	return undef if $self->is_path_ignored($path);
	$self->{absent_dir}->{$pb->{path}} ||= [];
	push @{$self->{absent_dir}->{$pb->{path}}}, $path;
	undef;
}

sub absent_file {
	my ($self, $path, $pb) = @_;
	return undef if $self->is_path_ignored($path);
	$self->{absent_file}->{$pb->{path}} ||= [];
	push @{$self->{absent_file}->{$pb->{path}}}, $path;
	undef;
}

sub change_file_prop {
	my ($self, $fb, $prop, $value) = @_;
	return undef if $self->is_path_ignored($fb->{path});
	if ($prop eq 'svn:executable') {
		if ($fb->{mode_b} != 120000) {
			$fb->{mode_b} = defined $value ? 100755 : 100644;
		}
	} elsif ($prop eq 'svn:special') {
		$fb->{mode_b} = defined $value ? 120000 : 100644;
	} else {
		$self->{file_prop}->{$fb->{path}} ||= {};
		$self->{file_prop}->{$fb->{path}}->{$prop} = $value;
	}
	undef;
}

sub apply_textdelta {
	my ($self, $fb, $exp) = @_;
	return undef if $self->is_path_ignored($fb->{path});
	my $suffix = 0;
	++$suffix while $::_repository->temp_is_locked("svn_delta_${$}_$suffix");
	my $fh = $::_repository->temp_acquire("svn_delta_${$}_$suffix");
	# $fh gets auto-closed() by SVN::TxDelta::apply(),
	# (but $base does not,) so dup() it for reading in close_file
	open my $dup, '<&', $fh or croak $!;
	my $base = $::_repository->temp_acquire("git_blob_${$}_$suffix");
	# close_file may call temp_acquire on 'svn_hash', but because of the
	# call chain, if the temp_acquire call from close_file ends up being the
	# call that first creates the 'svn_hash' temp file, then the FileHandle
	# that's created as a result will end up in an SVN::Pool that we clear
	# in SVN::Ra::gs_fetch_loop_common.  Avoid that by making sure the
	# 'svn_hash' FileHandle is already created before close_file is called.
	my $tmp_fh = $::_repository->temp_acquire('svn_hash');
	$::_repository->temp_release($tmp_fh, 1);

	if ($fb->{blob}) {
		my ($base_is_link, $size);

		if ($fb->{mode_a} eq '120000' &&
		    ! $self->{empty_symlinks}->{$fb->{path}}) {
			print $base 'link ' or die "print $!\n";
			$base_is_link = 1;
		}
	retry:
		$size = $::_repository->cat_blob($fb->{blob}, $base);
		die "Failed to read object $fb->{blob}" if ($size < 0);

		if (defined $exp) {
			seek $base, 0, 0 or croak $!;
			my $got = ::md5sum($base);
			if ($got ne $exp) {
				my $err = "Checksum mismatch: ".
				       "$fb->{path} $fb->{blob}\n" .
				       "expected: $exp\n" .
				       "     got: $got\n";
				if ($base_is_link) {
					warn $err,
					     "Retrying... (possibly ",
					     "a bad symlink from SVN)\n";
					$::_repository->temp_reset($base);
					$base_is_link = 0;
					goto retry;
				}
				die $err;
			}
		}
	}
	seek $base, 0, 0 or croak $!;
	$fb->{fh} = $fh;
	$fb->{base} = $base;
	[ SVN::TxDelta::apply($base, $dup, undef, $fb->{path}, $fb->{pool}) ];
}

sub close_file {
	my ($self, $fb, $exp) = @_;
	return undef if $self->is_path_ignored($fb->{path});

	my $hash;
	my $path = $self->git_path($fb->{path});
	if (my $fh = $fb->{fh}) {
		if (defined $exp) {
			seek($fh, 0, 0) or croak $!;
			my $got = ::md5sum($fh);
			if ($got ne $exp) {
				die "Checksum mismatch: $path\n",
				    "expected: $exp\n    got: $got\n";
			}
		}
		if ($fb->{mode_b} == 120000) {
			sysseek($fh, 0, 0) or croak $!;
			my $rd = sysread($fh, my $buf, 5);

			if (!defined $rd) {
				croak "sysread: $!\n";
			} elsif ($rd == 0) {
				warn "$path has mode 120000",
				     " but it points to nothing\n",
				     "converting to an empty file with mode",
				     " 100644\n";
				$fb->{mode_b} = '100644';
			} elsif ($buf ne 'link ') {
				warn "$path has mode 120000",
				     " but is not a link\n";
			} else {
				my $tmp_fh = $::_repository->temp_acquire(
					'svn_hash');
				my $res;
				while ($res = sysread($fh, my $str, 1024)) {
					my $out = syswrite($tmp_fh, $str, $res);
					defined($out) && $out == $res
						or croak("write ",
							Git::temp_path($tmp_fh),
							": $!\n");
				}
				defined $res or croak $!;

				($fh, $tmp_fh) = ($tmp_fh, $fh);
				Git::temp_release($tmp_fh, 1);
			}
		}

		$hash = $::_repository->hash_and_insert_object(
				Git::temp_path($fh));
		$hash =~ /^$::oid$/ or die "not an object ID: $hash\n";

		Git::temp_release($fb->{base}, 1);
		Git::temp_release($fh, 1);
	} else {
		$hash = $fb->{blob} or die "no blob information\n";
	}
	$fb->{pool}->clear;
	$self->{gii}->update($fb->{mode_b}, $hash, $path) or croak $!;
	print "\t$fb->{action}\t$path\n" if $fb->{action} && ! $::_q;
	undef;
}

sub abort_edit {
	my $self = shift;
	$self->{nr} = $self->{gii}->{nr};
	delete $self->{gii};
	$self->SUPER::abort_edit(@_);
}

sub close_edit {
	my $self = shift;

	# --- START FINAL PRODUCTION STRUCTURAL LINK BINDING ---
	if (defined $self->{_pending_externals} && $self->{gii}) {
		use IPC::Open2;
		eval {
			my $debug_active = $ENV{GIT_SVN_EXT_DEBUG} ? 1 : 0;

			if ($debug_active) {
				print STDERR "\n=== [GIT-SVN LINK DEBUG] START FINALIZE CYCLE ===\n";
			}
			
			# 1. Retrieve the absolute root URL of the entire SVN server repository
			my $repo_root_url = '';
			if ($repo_id) {
				$repo_root_url = eval { command_oneline('config', '--get', "svn-remote.$repo_id.reposRoot") } ||
				                 eval { command_oneline('config', '--get', "svn-remote.$repo_id.url") };
			}
			$repo_root_url =~ s/\/$// if $repo_root_url;

			if ($repo_root_url) {
				foreach my $ext (@{$self->{_pending_externals}}) {
					my $current_svn_dir = $ext->{path};
					my $gpath = $self->git_path($current_svn_dir);
					
					# 2. ISOLATION ENGINE: Dynamically extract the active SVN branch string layout prefix context
					# Matches: "trunk", "branches/name", "tags/name", or "somefolder" from raw paths.
					my $active_branch_path = '';
					if ($current_svn_dir =~ m{^(trunk|somefolder)(?:/|$)}) {
						$active_branch_path = $1;
					} elsif ($current_svn_dir =~ m{^(branches/[^/]+|tags/[^/]+)(?:/|$)}) {
						$active_branch_path = $1;
					}

					# Standardize the absolute folder server URL context path string sequences
					my $current_folder_url = $repo_root_url . "/" . $current_svn_dir;
					$current_folder_url =~ s/\/$//;

					if ($debug_active) {
						print STDERR "\nDEBUG: Processing SVN folder: '$current_svn_dir' -> Git path equivalent: '$gpath'\n";
						print STDERR "DEBUG: Identified Active Branch Context Prefix = '$active_branch_path'\n";
						print STDERR "DEBUG: Folder absolute SVN URL context = '$current_folder_url'\n";
					}

					foreach my $line (split(/\r?\n/, $ext->{value})) {
						next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
						$line =~ s/^\s+|\s+$//g;
						
						if ($debug_active) {
							print STDERR "--------------------------------------------------\n";
							print STDERR "DEBUG: Raw external entry line: '$line'\n";
						}
						
						if ($line =~ /^(.*?)\s+([^\s]+)$/) {
							my $ext_raw_url = $1;
							my $local_target_dir = $2;
							
							$ext_raw_url =~ s/^-r\s*\d+\s+//;
							
							my $resolved_abs_url = '';

							# 3. EXPAND RAW STRINGS TO ABSOLUTE PATH STRINGS
							if ($ext_raw_url =~ /^\^\/(.*)/) {
								$resolved_abs_url = $repo_root_url . "/" . $1;
							} elsif ($ext_raw_url =~ m{^(https?://|file://)}) {
								$resolved_abs_url = $ext_raw_url;
							} elsif ($ext_raw_url =~ /^\.\.\/(.*)/) {
								my @url_parts = split(/\//, $current_folder_url);
								my $rel_path = $ext_raw_url;
								while ($rel_path =~ s/^\.\.\///) {
									pop @url_parts;
								}
								$resolved_abs_url = join('/', @url_parts) . "/" . $rel_path;
							} else {
								$resolved_abs_url = $current_folder_url . "/" . $ext_raw_url;
							}
							
							$resolved_abs_url =~ s/\/$//;

							# 4. RESOLVE PURE INTRINSIC SERVER ROOT SNIPPET PATHS
							if ($resolved_abs_url =~ m{^\Q$repo_root_url\E/(.*)}) {
								my $target_inner_svn_path = $1; # e.g., "trunk/Media" or "branches/name/Media"
								
								# Extract target destination branch context prefix properties
								my $target_branch_path = '';
								if ($target_inner_svn_path =~ m{^(trunk|somefolder)(?:/|$)}) {
									$target_branch_path = $1;
								} elsif ($target_inner_svn_path =~ m{^(branches/[^/]+|tags/[^/]+)(?:/|$)}) {
									$target_branch_path = $1;
								}

								if ($debug_active) {
									print STDERR "DEBUG: Checking internal branch match metrics:\n";
									print STDERR "       Current context path branch = '$active_branch_path'\n";
									print STDERR "       Target definition path branch = '$target_branch_path'\n";
								}

								# 5. CORE VALIDATION: Verify external stays inside current branch context boundaries
								if ($active_branch_path ne '' && $active_branch_path eq $target_branch_path) {
									
									# Isolate target subpath details relative to the branch root folder area
									my $internal_git_source_path = $target_inner_svn_path;
									$internal_git_source_path =~ s/^\Q$active_branch_path\E\///; # e.g., "Media"

									my $link_placement = $gpath ? "$gpath/$local_target_dir" : $local_target_dir;
									
									# 6. UNIFORM RELATIVE PATH PREFIX GENERATOR
									my $current_depth = 0;
									if ($gpath && $gpath ne '') {
										my @directories = split(/\//, $gpath);
										$current_depth = scalar @directories;
									}
									
									my $relative_prefix = $current_depth > 0 ? ("../" x $current_depth) : "./";
									my $symlink_target_content = $relative_prefix . $internal_git_source_path;
									
									if ($debug_active) {
										print STDERR "DEBUG: MATCH SUCCESS! Inner branch path target = '$internal_git_source_path'\n";
										print STDERR "DEBUG: Final calculated relative target string = '$symlink_target_content'\n";
										print STDERR "DEBUG: Committing reference tree mapping      = '$link_placement' -> '$symlink_target_content'\n";
									}

									# 7. Stage and materialize link object data natively
									my ($ho_out, $ho_in);
									my $ho_pid = open2($ho_out, $ho_in, 'git', 'hash-object', '-w', '--stdin');
									print $ho_in $symlink_target_content;
									close($ho_in);
									my $link_sha = <$ho_out>;
									close($ho_out);
									waitpid($ho_pid, 0);
									chomp($link_sha);
									
									if ($link_sha =~ /^[0-9a-f]{40,64}$/) {
										$self->{gii}->update("120000", $link_sha, $link_placement);
										delete $self->{empty}->{$current_svn_dir} if exists $self->{empty}->{$current_svn_dir};
										
										if ($debug_active) {
											system('git', 'checkout-index', '-f', $link_placement);
										} else {
											system('git', 'checkout-index', '-f', $link_placement, '2>/dev/null');
										}
										print STDOUT "\tNatively committed directory link: $link_placement -> $symlink_target_content\n" unless $::_q;
									}
								} else {
									if ($debug_active) { print STDERR "DEBUG: MATCH FAILED! External path targets an out-of-branch location.\n"; }
									print STDOUT "\tSkipping external: $ext_raw_url (Points outside active branch context)\n" unless $::_q;
								}
							}
						}
					}
				}
			}
			if ($debug_active) {
				print STDERR "=== [GIT-SVN LINK DEBUG] END FINALIZE CYCLE ===\n\n";
			}
		};
		if ($@) {
			print STDERR "Warning: External directory link mapping encountered an error: $@\n";
		}
		delete $self->{_pending_externals};
	}
	# --- END FINAL PRODUCTION STRUCTURAL LINK BINDING ---

	if ($_preserve_empty_dirs) {
		my @empty_dirs;
		foreach my $i (keys %{$self->{empty}}) {
			push @empty_dirs, $i if exists $self->{dir_prop}->{$i};
		}
		push @empty_dirs, $self->find_empty_directories();
		$self->add_placeholder_file($_) foreach (@empty_dirs);
		$self->stash_placeholder_list();
	}

	$self->{git_commit_ok} = 1;
	$self->{nr} = $self->{gii}->{nr};
	delete $self->{gii};
	$self->SUPER::close_edit(@_);
}


sub find_empty_directories {
	my ($self) = @_;
	my @empty_dirs;
	my %dirs = map { dirname($_) => 1 } @deleted_gpath;

	foreach my $dir (sort keys %dirs) {
		next if $dir eq ".";

		# If there have been any additions to this directory, there is
		# no reason to check if it is empty.
		my $skip_added = 0;
		foreach my $t (qw/dir_prop file_prop/) {
			foreach my $path (keys %{ $self->{$t} }) {
				if (exists $self->{$t}->{dirname($path)}) {
					$skip_added = 1;
					last;
				}
			}
			last if $skip_added;
		}
		next if $skip_added;

		# Use `git ls-tree` to get the filenames of this directory
		# that existed prior to this particular commit.
		my $ls = command('ls-tree', '-z', '--name-only',
				 $self->{c}, "$dir/");
		my %files = map { $_ => 1 } split(/\0/, $ls);

		# Remove the filenames that were deleted during this commit.
		delete $files{$_} foreach (@deleted_gpath);

		# Report the directory if there are no filenames left.
		push @empty_dirs, $dir unless (scalar %files);
	}
	@empty_dirs;
}

sub add_placeholder_file {
	my ($self, $dir) = @_;
	my $path = "$dir/$_placeholder_filename";
	my $gpath = $self->git_path($path);

	my $fh = $::_repository->temp_acquire($gpath);
	my $hash = $::_repository->hash_and_insert_object(Git::temp_path($fh));
	Git::temp_release($fh, 1);
	$self->{gii}->update('100644', $hash, $gpath) or croak $!;

	# The directory should no longer be considered empty.
	delete $self->{empty}->{$dir} if exists $self->{empty}->{$dir};

	# Keep track of any placeholder files we create.
	$added_placeholder{$dir} = $path;
}

sub stash_placeholder_list {
	my ($self) = @_;
	my $k = "svn-remote.$repo_id.added-placeholder";
	my $v = eval { command_oneline('config', '--get-all', $k) };
	command_noisy('config', '--unset-all', $k) if $v;
	foreach (values %added_placeholder) {
		command_noisy('config', '--add', $k, $_);
	}
}

1;
__END__

=head1 NAME

Git::SVN::Fetcher - tree delta consumer for "git svn fetch"

=head1 SYNOPSIS

    use SVN::Core;
    use SVN::Ra;
    use Git::SVN;
    use Git::SVN::Fetcher;
    use Git;

    my $gs = Git::SVN->find_by_url($url);
    my $ra = SVN::Ra->new(url => $url);
    my $editor = Git::SVN::Fetcher->new($gs);
    my $reporter = $ra->do_update($SVN::Core::INVALID_REVNUM, '',
                                  1, $editor);
    $reporter->set_path('', $old_rev, 0);
    $reporter->finish_report;
    my $tree = $gs->tmp_index_do(sub { command_oneline('write-tree') });

    foreach my $path (keys %{$editor->{dir_prop}) {
        my $props = $editor->{dir_prop}{$path};
        foreach my $prop (keys %$props) {
            print "property $prop at $path changed to $props->{$prop}\n";
        }
    }
    foreach my $path (keys %{$editor->{empty}) {
        my $action = $editor->{empty}{$path} ? 'added' : 'removed';
        print "empty directory $path $action\n";
    }
    foreach my $path (keys %{$editor->{file_prop}) { ... }
    foreach my $parent (keys %{$editor->{absent_dir}}) {
        my @children = @{$editor->{abstent_dir}{$parent}};
        print "cannot fetch directory $parent/$_: not authorized?\n"
            foreach @children;
    }
    foreach my $parent (keys %{$editor->{absent_file}) { ... }

=head1 DESCRIPTION

This is a subclass of C<SVN::Delta::Editor>, which means it implements
callbacks to act as a consumer of Subversion tree deltas.  This
particular implementation of those callbacks is meant to store
information about the resulting content which B<git svn fetch> could
use to populate new commits and new entries for F<unhandled.log>.
More specifically:

=over

=item * Additions, removals, and modifications of files are propagated
to git-svn's index file F<$GIT_DIR/svn/$refname/index> using
B<git update-index>.

=item * Changes in Subversion path properties are recorded in the
C<dir_prop> and C<file_prop> fields (which are hashes).

=item * Addition and removal of empty directories are indicated by
entries with value 1 and 0 respectively in the C<empty> hash.

=item * Paths that are present but cannot be conveyed (presumably due
to permissions) are recorded in the C<absent_file> and
C<absent_dirs> hashes.  For each key, the corresponding value is
a list of paths under that directory that were present but
could not be conveyed.

=back

The interface is unstable.  Do not use this module unless you are
developing git-svn.

=head1 DEPENDENCIES

L<SVN::Delta> from the Subversion perl bindings,
the core L<Carp> and L<File::Basename> modules,
and git's L<Git> helper module.

C<Git::SVN::Fetcher> has not been tested using callers other than
B<git-svn> itself.

=head1 SEE ALSO

L<SVN::Delta>,
L<Git::SVN::Editor>.

=head1 INCOMPATIBILITIES

None reported.

=head1 BUGS

None.
