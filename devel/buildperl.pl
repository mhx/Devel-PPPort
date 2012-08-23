#!/usr/bin/perl -w
################################################################################
#
#  buildperl.pl -- build various versions of perl automatically
#
################################################################################
#
#  $Revision: 8 $
#  $Author: mhx $
#  $Date: 2006/01/14 21:41:11 +0000 $
#
################################################################################
#
#  Version 3.x, Copyright (C) 2004-2006, Marcus Holland-Moritz.
#  Version 2.x, Copyright (C) 2001, Paul Marquess.
#  Version 1.x, Copyright (C) 1999, Kenneth Albanowski.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the same terms as Perl itself.
#
################################################################################

use strict;
use Getopt::Long;
use Pod::Usage;
use File::Find;
use File::Path;
use Data::Dumper;
use IO::File;
use Archive::Tar;
use Cwd;

# TODO: - extra arguments to Configure

my %opt = (
  prefix  => '/tmp/perl/install/<config>/<perl>',
  build   => '/tmp/perl/build/<config>',
  source  => '/tmp/perl/source',
  force   => 0,
  test    => 0,
  install => 1,
);

my %config = (
  default     => {
	           config_args => '-des',
                 },
  thread      => {
	           config_args     => '-des -Dusethreads',
	           masked_versions => [ qr/^5\.00[01234]/ ],
                 },
  thread5005  => {
	           config_args     => '-des -Duse5005threads',
	           masked_versions => [ qr/^5\.00[012345]|^5.(9|\d\d)/ ],
                 },
  debug       => {
	           config_args => '-des -Doptimize=-g',
                 },
);

my @patch = (
  {
    perl => [
              qr/^5\.00[01234]/,
              qw/
                5.005
                5.005_01
                5.005_02
                5.005_03
              /,
            ],
    subs => [
              [ \&patch_db, 1 ],
            ],
  },
  {
    perl => [
     	      qw/
                5.6.0
                5.6.1
                5.7.0
                5.7.1
                5.7.2
                5.7.3
                5.8.0
     	      /,
            ],
    subs => [
              [ \&patch_db, 3 ],
            ],
  },
  {
    perl => [
              qr/^5\.004_0[1234]/,
            ],
    subs => [
              [ \&patch_doio ],
            ],
  },
);

my(%perl, @perls);

GetOptions(\%opt, qw(
  config=s@
  prefix=s
  build=s
  source=s
  perl=s@
  force
  test
  install!
)) or pod2usage(2);

if (exists $opt{config}) {
  for my $cfg (@{$opt{config}}) {
    exists $config{$cfg} or die "Unknown configuration: $cfg\n";
  }
}
else {
  $opt{config} = [sort keys %config];
}

find(sub {
  /^(perl-?(5\..*))\.tar\.(gz|bz2)$/ or return;
  $perl{$1} = { version => $2, source => $File::Find::name, compress => $3 };
}, $opt{source});

if (exists $opt{perl}) {
  for my $perl (@{$opt{perl}}) {
    my $p = $perl;
    exists $perl{$p} or $p = "perl$perl";
    exists $perl{$p} or $p = "perl-$perl";
    exists $perl{$p} or die "Cannot find perl: $perl\n";
    push @perls, $p;
  }
}
else {
  @perls = sort keys %perl;
}

my %current;

for my $cfg (@{$opt{config}}) {
  for my $perl (@perls) {
    my $config = $config{$cfg};
    %current = (config => $cfg, perl => $perl, version => $perl{$perl}{version});

    if (is($config->{masked_versions}, $current{version})) {
      print STDERR "skipping $perl for configuration $cfg (masked)\n";
      next;
    }

    if (-d expand($opt{prefix}) and !$opt{force}) {
      print STDERR "skipping $perl for configuration $cfg (already installed)\n";
      next;
    }

    my $cwd = cwd;

    my $build = expand($opt{build});
    -d $build or mkpath($build);
    chdir $build or die "chdir $build: $!\n";

    print STDERR "building $perl with configuration $cfg\n";
    buildperl($perl, $config);

    chdir $cwd or die "chdir $cwd: $!\n";
  }
}

sub expand
{
  my $in = shift;
  $in =~ s/(<(\w+)>)/exists $current{$2} ? $current{$2} : $1/eg;
  return $in;
}

sub is
{
  my($s1, $s2) = @_;

  defined $s1 != defined $s2 and return 0;

  ref $s2 and ($s1, $s2) = ($s2, $s1);

  if (ref $s1) {
    if (ref $s1 eq 'ARRAY') {
      is($_, $s2) and return 1 for @$s1;
      return 0;
    }
    return $s2 =~ $s1;
  }

  return $s1 eq $s2;
}

sub buildperl
{
  my($perl, $cfg) = @_;

  my $d = extract_source($perl{$perl});
  chdir $d or die "chdir $d: $!\n";

  patch_source($perl{$perl}{version});

  build_and_install($perl{$perl});
}

sub extract_source
{
  my $perl = shift;

  print "reading $perl->{source}\n";

  my $target;

  for my $f (Archive::Tar->list_archive($perl->{source})) {
    my($t) = $f =~ /^([^\\\/]+)/ or die "ooops, should always match...\n";
    die "refusing to extract $perl->{source}, as it would not extract to a single directory\n"
        if defined $target and $target ne $t;
    $target = $t;
  }

  if (-d $target) {
    print "removing old build directory $target\n";
    rmtree($target);
  }

  print "extracting $perl->{source}\n";

  Archive::Tar->extract_archive($perl->{source})
      or die "extract failed: " . Archive::Tar->error() . "\n";

  -d $target or die "oooops, $target not found\n";

  return $target;
}

sub patch_source
{
  my $version = shift;

  for my $p (@patch) {
    if (is($p->{perl}, $version)) {
      for my $s (@{$p->{subs}}) {
        my($sub, @args) = @$s;
        $sub->(@args);
      }
    }
  }
}

sub build_and_install
{
  my $perl = shift;
  my $prefix = expand($opt{prefix});

  print "building perl $perl->{version} ($current{config})\n";

  run_or_die("./Configure $config{$current{config}}{config_args} -Dusedevel -Uinstallusrbinperl -Dprefix=$prefix");
  run_or_die("sed -i -e '/^.*<built-in>/d' -e '/^.*<command line>/d' makefile x2p/makefile");
  run_or_die("make all");
  run("make test") if $opt{test};
  if ($opt{install}) {
    run_or_die("make install");
  }
  else {
    print "\n*** NOT INSTALLING PERL ***\n\n";
  }
}

sub patch_db
{
  my $ver = shift;
  print "patching DB_File\n";
  run_or_die("sed -i -e 's/<db.h>/<db$ver\\/db.h>/' ext/DB_File/DB_File.xs");
}

sub patch_doio
{
  patch('doio.c', <<'END');
--- doio.c.org	2004-06-07 23:14:45.000000000 +0200
+++ doio.c	2003-11-04 08:03:03.000000000 +0100
@@ -75,6 +75,16 @@
 #  endif
 #endif

+#if _SEM_SEMUN_UNDEFINED
+union semun
+{
+  int val;
+  struct semid_ds *buf;
+  unsigned short int *array;
+  struct seminfo *__buf;
+};
+#endif
+
 bool
 do_open(gv,name,len,as_raw,rawmode,rawperm,supplied_fp)
 GV *gv;
END
}

sub patch
{
  my($file, $patch) = @_;
  print "patching $file\n";
  my $diff = "$file.diff";
  write_or_die($diff, $patch);
  run_or_die("patch -s -p0 <$diff");
  unlink $diff or die "unlink $diff: $!\n";
}

sub write_or_die
{
  my($file, $data) = @_;
  my $fh = new IO::File ">$file" or die "$file: $!\n";
  $fh->print($data);
}

sub run_or_die
{
  # print "[running @_]\n";
  system "@_" and die "@_: $?\n";
}

sub run
{
  # print "[running @_]\n";
  system "@_" and warn "@_: $?\n";
}

__END__

=head1 NAME

buildperl.pl - build/install perl distributions

=head1 SYNOPSIS

  perl buildperl.pl [options]

  --help                      show this help

  --source=directory          directory containing source tarballs
                              [default: /tmp/perl/source]

  --build=directory           directory used for building perls [EXPAND]
                              [default: /tmp/perl/build/<config>]

  --prefix=directory          use this installation prefix [EXPAND]
                              [default: /tmp/perl/install/<config>/<perl>]

  --config=configuration      build this configuration [MULTI]
                              [default: all possible configurations]

  --perl=version              build this version of perl [MULTI]
                              [default: all possible versions]

  --force                     rebuild and install already installed versions

  --test                      run test suite after building

  --noinstall                 don't install after building

  options tagged with [MULTI] can be given multiple times

  options tagged with [EXPAND] expand the following items

    <perl>      versioned perl directory  (e.g. 'perl-5.6.1')
    <version>   perl version              (e.g. '5.6.1')
    <config>    name of the configuration (e.g. 'default')

=head1 EXAMPLES

The following examples assume that your Perl source tarballs are
in F</tmp/perl/source>. If they are somewhere else, use the C<--source>
option to specify a different source directory.

To build a default configuration of perl5.004_05 and install it
to F</opt/perl5.004_05>, you would say:

  buildperl.pl --prefix='/opt/<perl>' --perl=5.004_05 --config=default

To build debugging configurations of all perls in the source directory
and install them to F</opt>, use:

  buildperl.pl --prefix='/opt/<perl>' --config=debug

To build all configurations for perl-5.8.5 and perl-5.8.6, test them
and don't install them, run:

  buildperl.pl --perl=5.8.5 --perl=5.8.6 --test --noinstall

=head1 COPYRIGHT

Copyright (c) 2004-2005, Marcus Holland-Moritz.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

See L<Devel::PPPort>.

