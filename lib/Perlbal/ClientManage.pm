######################################################################
# Management connection from a client
######################################################################

package Perlbal::ClientManage;
use strict;
use base "Perlbal::Socket";
use fields qw(service buf);

# ClientManage
sub new {
    my ($class, $service, $sock) = @_;
    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{buf} = "";   # what we've read so far, not forming a complete line
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# ClientManage
sub event_read {
    my $self = shift;

    my $bref = $self->read(1024);
    return $self->close() unless defined $bref;
    $self->{buf} .= $$bref;

    if ($self->{buf} =~ s/^(.+?)\r?\n//) {
        my $line = $1;
        Perlbal::run_manage_command($line, sub {
            $self->write("$_[0]\r\n");
        });
    }
}

# ClientManage
sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
