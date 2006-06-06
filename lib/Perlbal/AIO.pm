# AIO abstraction layer
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.

package Perlbal::AIO;

use Fcntl qw(SEEK_CUR SEEK_SET SEEK_END);

sub aio_readahead {
    my ($fh, $offset, $length, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_readahead($fh, $offset, $length, $cb);
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_readahead($fh, $offset, $length, $cb);
    } else {
        $cb->();
    }
}

sub aio_stat {
    my ($file, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_stat($file, $cb);
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_stat($file, $cb);
    } else {
        stat($file);
        $cb->();
    }
}

sub _fh_of_fd_mode {
    my ($fd, $mode) = @_;
    return undef unless defined $fd && $fd >= 0;

    #TODO: use the write MODE for the given $mode;
    my $fh = IO::Handle->new_from_fd($fd, 'r+');
    my $num = fileno($fh);
    return $fh;
}

sub aio_open {
    my ($file, $flags, $mode, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_open($file, $flags, $mode, sub {
            my $fd = shift;
            my $fh = _fh_of_fd_mode($fd, $mode);
            $cb->($fh);
        });
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_open($file, $flags, $mode, $cb);
    } else {
        my $fh;
        my $rv = sysopen($fh, $file, $flags, $mode);
        $cb->($rv ? $fh : undef);
    }
}

sub aio_unlink {
    my ($file, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_unlink($file, $cb);
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_unlink($file, $cb);
    } else {
        my $rv = unlink($file);
        $rv = $rv ? 0 : -1;
        $cb->($rv);
    }
}

sub aio_write {
    #   0    1        2        3(data) 4
    my ($fh, $offset, $length, undef,  $cb) = @_;
    return no_fh($cb) unless $fh;

    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_write($fh, $offset, $length, $_[3], 0, $cb);
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_write($fh, $offset, $length, $_[3], 0, $cb);
    } else {
        my $old_off = sysseek($fh, 0, SEEK_CUR);
        sysseek($fh, $offset, 0);
        my $rv = syswrite($fh, $_[3], $length, 0);
        sysseek($fh, $old_off, SEEK_SET);
        $cb->($rv);
    }
}

sub aio_read {
    #   0    1        2        3(data) 4
    my ($fh, $offset, $length, undef,  $cb) = @_;
    return no_fh($cb) unless $fh;

    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_read($fh, $offset, $length, $_[3], 0, $cb);
    } elsif ($Perlbal::AIO_MODE eq "ioaio") {
        IO::AIO::aio_read($fh, $offset, $length, $_[3], 0, $cb);
    } else {
        my $old_off = sysseek($fh, 0, SEEK_CUR);
        sysseek($fh, $offset, 0);
        my $rv = sysread($fh, $_[3], $length, 0);
        sysseek($fh, $old_off, SEEK_SET);
        $cb->($rv);
    }
}

sub no_fh {
    my $cb = shift;

    my $i = 1;
    my $stack_trace = "";
    while (my ($pkg, $filename, $line, $subroutine, $hasargs,
               $wantarray, $evaltext, $is_require, $hints, $bitmask) = caller($i++)) {
        $stack_trace .= " at $filename:$line $subroutine\n";
    }

    Perlbal::log("crit", "Undef \$fh: $stack_trace");
    $cb->(undef);
    return undef;
}

1;
