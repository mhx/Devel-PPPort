#!/usr/bin/perl -w
################################################################################
#
#  apicheck.pl -- generate apicheck.c: C source for automated API check
#
#  WARNING:  This script will be run on very old perls.  You need to not use
#            modern constructs.  See HACKERS file for examples.
#
################################################################################
#
#  Version 3.x, Copyright (C) 2004-2013, Marcus Holland-Moritz.
#  Version 2.x, Copyright (C) 2001, Paul Marquess.
#  Version 1.x, Copyright (C) 1999, Kenneth Albanowski.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the same terms as Perl itself.
#
################################################################################

use strict;
require './parts/ppptools.pl';

if (@ARGV) {
  my $file = pop @ARGV;
  open OUT, ">$file" or die "$file: $!\n";
}
else {
  *OUT = \*STDOUT;
}

# Arguments passed to us in this variable are of the form
# '--a=foo --b=bar', so split first on space, then the =, and then the hash is
# of the form { a => foo, b => bar }
my %script_args = map { split /=/ } split(/\s+/, $ENV{'DPPP_ARGUMENTS'});

# Get list of functions/macros to test
my @f = parse_embed(qw( parts/embed.fnc parts/apidoc.fnc parts/ppport.fnc ));

# Read in what we've decided in previous calls should be #ifdef'd out for this
# call.  The keys are the symbols to test; each value is a subhash, like so:
#     'utf8_hop_forward' => {
#                               'version' => '5.025007'
#                           },
# We don't care here about other subkeys
my %todo = %{&parse_todo($script_args{'--todo-dir'})};

# We convert these types into these other types
my %tmap = (
  void => 'int',
);

# These are for special marker argument names, as mentioned in embed.fnc
my %amap = (
  SP   => 'SP',
  type => 'int',
  cast => 'int',
  block => '{1;}',
  number => '1',
);

# Certain return types are instead considered void
my %void = (
  void     => 1,
  Free_t   => 1,
  Signal_t => 1,
);

# khw doesn't know why these exist.  These have an explicit (void) cast added.
# Undef'ing this hash made no difference.  Maybe it's for older compilers?
my %castvoid = (
  map { ($_ => 1) } qw(
    G_ARRAY
    G_DISCARD
    G_EVAL
    G_NOARGS
    G_SCALAR
    G_VOID
    HEf_SVKEY
    MARK
    Nullav
    Nullch
    Nullcv
    Nullhv
    Nullsv
    SP
    SVt_IV
    SVt_NV
    SVt_PV
    SVt_PVAV
    SVt_PVCV
    SVt_PVHV
    SVt_PVMG
    SvUOK
    XS_VERSION
  ),
);

# Ignore the return value of these
my %ignorerv = (
  map { ($_ => 1) } qw(
    newCONSTSUB
  ),
);

my @simple_my_cxt_prereqs = ( 'typedef struct { int count; } my_cxt_t;', 'START_MY_CXT;' );
my @my_cxt_prereqs = ( @simple_my_cxt_prereqs, 'MY_CXT_INIT;' );

# The value of each key is a list of things that need to be declared in order
# for the key to compile.
my %stack = (
  MULTICALL      => ['dMULTICALL;'],
  ORIGMARK       => ['dORIGMARK;'],
  POP_MULTICALL  => ['dMULTICALL;', 'U8 gimme;' ],
  PUSH_MULTICALL => ['dMULTICALL;', 'U8 gimme;' ],
  POPpbytex      => ['STRLEN n_a;'],
  POPpx          => ['STRLEN n_a;'],
  PUSHi          => ['dTARG;'],
  PUSHn          => ['dTARG;'],
  PUSHp          => ['dTARG;'],
  PUSHu          => ['dTARG;'],
  RESTORE_LC_NUMERIC => ['DECLARATION_FOR_LC_NUMERIC_MANIPULATION;'],
  STORE_LC_NUMERIC_FORCE_TO_UNDERLYING => ['DECLARATION_FOR_LC_NUMERIC_MANIPULATION;'],
  STORE_LC_NUMERIC_SET_TO_NEEDED => ['DECLARATION_FOR_LC_NUMERIC_MANIPULATION;'],
  STORE_LC_NUMERIC_SET_TO_NEEDED_IN => ['DECLARATION_FOR_LC_NUMERIC_MANIPULATION;'],
  TARG           => ['dTARG;'],
  UNDERBAR       => ['dUNDERBAR;'],
  XCPT_CATCH     => ['dXCPT;'],
  XCPT_RETHROW   => ['dXCPT;'],
  XCPT_TRY_END   => ['dXCPT;'],
  XCPT_TRY_START => ['dXCPT;'],
  XPUSHi         => ['dTARG;'],
  XPUSHn         => ['dTARG;'],
  XPUSHp         => ['dTARG;'],
  XPUSHu         => ['dTARG;'],
  XS_APIVERSION_BOOTCHECK => ['CV * cv;'],
  XS_VERSION_BOOTCHECK => ['CV * cv;'],
  MY_CXT_INIT  => [ @simple_my_cxt_prereqs ],
  MY_CXT_CLONE => [ @simple_my_cxt_prereqs ],
  dMY_CXT      => [ @simple_my_cxt_prereqs ],
  MY_CXT       => [ @my_cxt_prereqs ],
  _aMY_CXT     => [ @my_cxt_prereqs ],
   aMY_CXT     => [ @my_cxt_prereqs ],
   aMY_CXT_    => [ @my_cxt_prereqs ],
   pMY_CXT     => [ @my_cxt_prereqs ],
);

# The entries in %ignore have two components, separated by this.
my $sep = '~';

# Things to not try to check.  (The component after $sep is empty.)
my %ignore = map { ("$_$sep" => 1) } keys %{&known_but_hard_to_test_for()};

print OUT <<HEAD;
/*
 * !!!!!!!   DO NOT EDIT THIS FILE   !!!!!!!
 * This file is built by $0.
 * Any changes made here will be lost!
 */

#include "EXTERN.h"
#include "perl.h"
HEAD

# These may not have gotten #included, and don't exist in all versions
my $hdr;
for $hdr (qw(time64 perliol malloc_ctl perl_inc_macro patchlevel)) {
    my $dir;
    for $dir (@INC) {
        if (-e "$dir/CORE/$hdr.h") {
            print OUT "#include \"$hdr.h\"\n";
            last;
        }
    }
}

print OUT <<HEAD;

#define NO_XSLOCKS
#include "XSUB.h"

#ifdef DPPP_APICHECK_NO_PPPORT_H

/* This is just to avoid too many baseline failures with perls < 5.6.0 */

#ifndef dTHX
#  define dTHX extern int Perl___notused
#endif

#else

$ENV{'DPPP_NEED'}    /* All the requisite NEED_foo #defines */

#include "ppport.h"

#endif

static int    VARarg1;
static char  *VARarg2;
static double VARarg3;

#if defined(PERL_BCDVERSION) && (PERL_BCDVERSION < 0x5009005)
/* needed to make PL_parser apicheck work */
typedef void yy_parser;
#endif

/* Handle both 5.x.y and 7.x.y and up
#ifndef PERL_VERSION_MAJOR
#  define PERL_VERSION_MAJOR PERL_REVISION
#endif
#ifndef PERL_VERSION_MINOR
#  define PERL_VERSION_MINOR PERL_VERSION
#endif
#ifndef PERL_VERSION_PATCH
#  define PERL_VERSION_PATCH PERL_SUBVERSION
#endif

/* This causes some functions to compile that otherwise wouldn't, so we can
 * get their info; and doesn't seem to harm anything */
#define PERL_IMPLICIT_CONTEXT

HEAD

# Caller can restrict what functions tests are generated for
if (@ARGV) {
  my %want = map { ($_ => 0) } @ARGV;
  @f = grep { exists $want{$_->{'name'}} } @f;
  for (@f) { $want{$_->{'name'}}++ }
  for (keys %want) {
    die "nothing found for '$_'\n" unless $want{$_};
  }
}

my $f;
for $f (@f) {   # Loop through all the tests to add

  # Just the name isn't unique;  We also need the #if or #else condition
  my $unique = "$f->{'name'}$sep$f->{'cond'}";
  $ignore{$unique} and next;

  # only public API members, except those in ppport.fnc are there because we
  # want them to be tested even if non-public.  X,M functions are supposed to
  # be considered to have just the macro form public.
      $f->{'flags'}{'A'}
  or  $f->{'ppport_fnc'}
  or ($f->{'flags'}{'X'} and $f->{'flags'}{'M'})
  or next;

  # Don't test unorthodox things that we aren't set up to do
  $f->{'flags'}{'u'} and next;

  $ignore{$unique} = 1; # ignore duplicates

  my $Perl_ = $f->{'flags'}{'p'} ? 'Perl_' : '';

  my $stack = '';
  my @arg;
  my $aTHX = '';

  my $i = 1;
  my $ca;
  my $varargs = 0;

  for $ca (@{$f->{'args'}}) {   # Loop through the function's args
    my $a = $ca->[0];           # 1th is the name, 0th is its type
    if ($a eq '...') {
      $varargs = 1;
      push @arg, qw(VARarg1 VARarg2 VARarg3);
      last;
    }

    # Split this type into its components
    my($n, $p, $d) = $a =~ /^ (  (?: " [^"]* " )      # literal string type => $n
                               | (?: \w+ (?: \s+ \w+ )* )    # name of type => $n
                              )
                              \s*
                              ( \** )                 # optional pointer(s) => $p
                              (?: \s* \b const \b \s* )? # opt. const
                              ( (?: \[ [^\]]* \] )* )    # opt. dimension(s)=> $d
                            $/x
                     or die "$0 - cannot parse argument: [$a] in $f->{'name'}\n";

    # Replace a special argument name by something that will compile.
    if (exists $amap{$n}) {
      die "$f->{'name'} had type $n, which should have been the whole type"
                                                                    if $p or $d;
      push @arg, $amap{$n};
      next;
    }

    # Certain types, like 'void', get remapped.
    $n = $tmap{$n} || $n;

    if ($n =~ / ^ " [^"]* " $/x) {  # Use the literal string, literally
      push @arg, $n;
    }
    else {
      my $v = 'arg' . $i++;     # Argument number
      push @arg, $v;
      my $no_const_n = $n;      # Get rid of any remaining 'const's
      $no_const_n =~ s/\bconst\b// unless $p;

      # Declare this argument
      $stack .= "  static $no_const_n $p$v$d;\n";
    }
  }

  # Declare thread context for functions and macros that might need it.
  # (Macros often fail to say they don't need it.)
  unless ($f->{'flags'}{'T'}) {
    $stack = "  dTHX;\n$stack";     # Harmless to declare even if not needed
    $aTHX = @arg ? 'aTHX_ ' : 'aTHX';
  }

  # If this function is on the list of things that need declarations, add
  # them.
  if ($stack{$f->{'name'}}) {
    my $s = '';
    for (@{$stack{$f->{'name'}}}) {
      $s .= "  $_\n";
    }
    $stack = "$s$stack";
  }

  my $args = join ', ', @arg;
  my $prefix = "";

  # Failure to specify a return type in the apidoc line means void
  my $rvt = $f->{'ret'} || 'void';

  my $ret;
  if ($void{$rvt}) {    # Certain return types are instead considered void
    $ret = $castvoid{$f->{'name'}} ? '(void) ' : '';
  }
  else {
    $stack .= "  $rvt rval;\n";
    $ret = $ignorerv{$f->{'name'}} ? '(void) ' : "rval = ";
  }

  my $THX_prefix = "";
  my $THX_suffix = "";

  # Add parens to functions that take an argument list, even if empty
  unless ($f->{'flags'}{'n'}) {
    $THX_suffix = "($aTHX$args)";
    $args = "($args)";
  }

  # Single trailing underscore in name means is a comma operator
  if ($f->{'name'} =~ /[^_]_$/) {
    $THX_suffix .= ' 1';
    $args .= ' 1';
  }

  # Single leading underscore in a few names means is a comma operator
  if ($f->{'name'} =~ /^ _[ adp] (?: THX | MY_CXT ) /x) {
    $THX_prefix = '1 ';
    $prefix = '1 ';
  }


  print OUT <<HEAD;
/******************************************************************************
*

*  $f->{'name'}  $script_args{'--todo-dir'}  $script_args{'--todo'}
*
******************************************************************************/

HEAD

  # #ifdef out if marked as todo (not known in) this version
  if (exists $todo{$f->{'name'}}) {
    my($rev, $ver,$sub) = parse_version($todo{$f->{'name'}}{'version'});
    print OUT <<EOT;
#if       PERL_VERSION_MAJOR > $rev                         \\
   || (   PERL_VERSION_MAJOR == $rev                        \\
       && (   PERL_VERSION_MINOR > $ver                     \\
           || (   PERL_VERSION_MINOR == $ver                \\
               && PERL_VERSION_PATCH >= $sub))) /* TODO */
EOT
  }

  my $final = $varargs
              ? "$THX_prefix$Perl_$f->{'name'}$THX_suffix"
              : "$prefix$f->{'name'}$args";

  # If there is a '#if' associated with this, add that
  $f->{'cond'} and print OUT "#if $f->{'cond'}\n";

  # If only to be tested when ppport.h is enabled
  $f->{'ppport_fnc'} and print OUT "#ifndef DPPP_APICHECK_NO_PPPORT_H\n";

  print OUT <<END;
void DPPP_test_$f->{'name'} (void)
{
  dXSARGS;
$stack
  {
END

  # If M is a flag here, it means the 'Perl_' form is not for general use, but
  # the macro (tested above) is.
  if ($f->{'flags'}{'M'}) {
      print OUT <<END;

    $ret$prefix$f->{'name'}$args;
  }
}
END

  }
  else {
    print OUT <<END;

#ifdef $f->{'name'}
    $ret$prefix$f->{'name'}$args;
#endif
  }

  {
#ifdef $f->{'name'}
    $ret$final;
#else
    $ret$THX_prefix$Perl_$f->{'name'}$THX_suffix;
#endif
  }
}
END

  }

  $f->{'ppport_fnc'} and print OUT "#endif\n";
  $f->{'cond'} and print OUT "#endif\n";
  exists $todo{$f->{'name'}} and print OUT "#endif\n";

  print OUT "\n";
}

@ARGV and close OUT;
