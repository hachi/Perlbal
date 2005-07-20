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
    VERSION                 => '1.2',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT_FROM           => 'perlbal',

    (
      exists($ENV{DANGABUILD_MODULESONLY}) ?
      () :
      (EXE_FILES               => [ 'perlbal' ]),
    ),

    PREREQ_PM               => {
        'Danga::Socket' => '1.43',
        'BSD::Resource' => 0,
        'Test::More' => 0,
        'File::Find' => 0,
    },
    dist                    => {
        CI                      => "cvs commit",
        RCS_LABEL               => 'cvs tag RELEASE_$(VERSION_SYM)',
        SUFFIX                  => ".gz",
        DIST_DEFAULT            => 'all tardist',
        COMPRESS                => "gzip",
    },

    (
      exists($ENV{DANGABUILD_DAEMONONLY}) ?
      (PM => {}, PMLIBDIRS => []):
      (),
    ),

);

