=head1 NAME

Perlbal::Plugin::Include - Allows multiple, nesting configuration files

=head1 DESCRIPTION

This module adds an INCLUDE command to the Perlbal management console
and allows the globbed inclusion of configuration files.

=head1 SYNOPSIS

This module provides a Perlbal plugin which can be loaded and used as
follows:

    LOAD include
    INCLUDE = /etc/perlbal/my.conf

You may also specify multiple configuration files a la File::Glob:

    INCLUDE = /foo/bar.conf /foo/quux/*.conf

=head1 BUGS AND LIMITATIONS

This module relies entirely on Perlbal::load_config for loading, so if
you have trouble with INCLUDE, be sure you can load the same
configuration without error using "perlbal -c" first.

Also note that Perlbal::load_config versions 1.60 and below do not use
a local filehandle while reading the configuration file, so this
module overrides that routine on load to allow nested calls.

=head1 COPYRIGHT AND LICENSE

Copyright 2008 Eamon Daly <eamon@eamondaly.com>

This module is part of the Perlbal distribution, and as such can be
distributed under the same licence terms as the rest of Perlbal.

=cut

package Perlbal::Plugin::Include;

use strict;
use warnings;
no  warnings qw(deprecated);

if ($Perlbal::VERSION <= 1.60) {
    *Perlbal::load_config = *Perlbal::Plugin::Include::load_config_local;
}

# called when we are loaded
sub load {
    my $class = shift;

    Perlbal::register_global_hook('manage_command.include', sub {
        my $mc = shift->parse(qr/^include\s+=\s+(.+)\s*$/,
			      "usage: INCLUDE = <config files>");

        my ($glob) = $mc->args;

	for (glob($glob)) {
	    Perlbal::load_config($_, sub { print STDOUT "$_[0]\n"; });
	}

        return $mc->ok;
    });

    return 1;
}

# called for a global unload
sub unload {
    # unregister our global hooks
    Perlbal::unregister_global_hook('manage_command.include');

    return 1;
}

# In older versions of Perlbal, load_config uses a typeglob, throwing
# warnings when re-entering. This uses a locally-scoped filehandle.
sub load_config_local {
    my ($file, $writer) = @_;
    open(my $fh, $file) or die "Error opening config file ($file): $!\n";
    my $ctx = Perlbal::CommandContext->new;
    $ctx->verbose(0);
    while (my $line = <$fh>) {
        $line =~ s/\$(\w+)/$ENV{$1}/g;
        return 0 unless Perlbal::run_manage_command($line, $writer, $ctx);
    }
    close($fh);
    return 1;
}

1;
