#!/usr/bin/perl
#
#   Perl Makefile for Perlbal
#   $Id$
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Perlbal',
    VERSION_FROM            => 'lib/Perlbal.pm',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT_FROM           => 'perlbal',

    (
      exists($ENV{DANGABUILD_MODULESONLY}) ?
      () :
      (EXE_FILES               => [ 'perlbal' ]),
    ),

    PREREQ_PM               => {
        'Danga::Socket' => '1.44',
        'Sys::Syscall'  => 0,
        'BSD::Resource' => 0,
        'HTTP::Date'    => 0,
        'HTTP::Response' => 0,
        'Test::More'    => 0,
        'File::Find'    => 0,
        'Time::HiRes'   => 0,
        'LWP::UserAgent' => 0,
        #'IO::AIO'  => 1.6,     # recommened.
    },

    (
      exists($ENV{DANGABUILD_DAEMONONLY}) ?
      (PM => {}, PMLIBDIRS => []):
      (),
    ),

);

sub MY::postamble {
    my $tab = chr(9);
    return <<MAKE_FRAG;
docs :: docs/service-parameters.txt

docs/service-parameters.txt: lib/Perlbal/Service.pm
${tab}devtools/gendocs.pl service-parameters

MAKE_FRAG
}
