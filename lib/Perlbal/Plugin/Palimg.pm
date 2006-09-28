###########################################################################
# Palimg plugin that allows Perlbal to serve palette altered images
###########################################################################

package Perlbal::Plugin::Palimg;

use strict;
use warnings;
no  warnings qw(deprecated);

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # verify that an incoming request is a palimg request
    $svc->register_hook('Palimg', 'start_serve_request', sub {
        my Perlbal::ClientHTTPBase $obj = $_[0];
        return 0 unless $obj;
        my Perlbal::HTTPHeaders $hd = $obj->{req_headers};
        my $uriref = $_[1];
        return 0 unless $uriref;

        # if this is palimg, peel off the requested modifications and put in headers
        return 0 unless $$uriref =~ m!^/palimg/(.+)\.(\w+)(.*)$!;
        my ($fn, $ext, $extra) = ($1, $2, $3);
        return 0 unless $extra;
        my ($palspec) = $extra =~ m!^/p(.+)$!;
        return 0 unless $fn && $palspec;

        # must be ok, setup for it
        $$uriref = "/palimg/$fn.$ext";
        $obj->{scratch}->{palimg} = [ $ext, $palspec ];
        return 0;
    });

    # actually serve a palimg
    $svc->register_hook('Palimg', 'start_send_file', sub {
        my Perlbal::ClientHTTPBase $obj = $_[0];
        return 0 unless $obj &&
                        (my $palimginfo = $obj->{scratch}->{palimg});

        # turn off writes
        $obj->watch_write(0);

        # create filehandle for reading
        my $data = '';
        Perlbal::AIO::aio_read($obj->reproxy_fh, 0, 2048, $data, sub {
            # got data? undef is error
            return $obj->_simple_response(500) unless $_[0] > 0;

            # pass down to handler
            my Perlbal::HTTPHeaders $hd = $obj->{req_headers};
            my $res = PalImg::modify_file(\$data, $palimginfo->[0], $palimginfo->[1]);
            return $obj->_simple_response(500) unless defined $res;
            return $obj->_simple_response($res) if $res;

            # seek into the file now so sendfile starts further in
            my $ld = length $data;
            sysseek($obj->{reproxy_fh}, $ld, &POSIX::SEEK_SET);
            $obj->{reproxy_file_offset} = $ld;

            # reenable writes after we get data
            $obj->tcp_cork(1); # by setting reproxy_file_offset above, it won't cork, so we cork it
            $obj->write($data);
            $obj->watch_write(1);
        });

        return 1;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    $svc->unregister_hooks('Palimg');
    return 1;
}

# called when we are loaded/unloaded ... someday add some stats viewing
# commands here?
sub load { return 1; }
sub unload { return 1; }

####### PALIMG START ###########################################################################
package PalImg;

sub parse_hex_color
{
    my $color = shift;
    return [ map { hex(substr($color, $_, 2)) } (0,2,4) ];
}

sub modify_file
{
    my ($data, $type, $palspec) = @_;

    # palette altering
    my %pal_colors;
    if (my $pals = $palspec) {
        my $hx = "[0-9a-f]";
        if ($pals =~ /^g($hx{2,2})($hx{6,6})($hx{2,2})($hx{6,6})$/) {
            # gradient from index $1, color $2, to index $3, color $4
            my $from = hex($1);
            my $to = hex($3);
            return 404 if $from == $to;
            my $fcolor = parse_hex_color($2);
            my $tcolor = parse_hex_color($4);
            if ($to < $from) {
                ($from, $to, $fcolor, $tcolor) =
                    ($to, $from, $tcolor, $fcolor);
            }
            for (my $i=$from; $i<=$to; $i++) {
                $pal_colors{$i} = [ map {
                    int($fcolor->[$_] +
                        ($tcolor->[$_] - $fcolor->[$_]) *
                        ($i-$from) / ($to-$from))
                    } (0..2)  ];
            }
        } elsif ($pals =~ /^t($hx{6,6})($hx{6,6})?$/) {
            # tint everything towards color
            my ($t, $td) = ($1, $2);
            $pal_colors{'tint'} = parse_hex_color($t);
            $pal_colors{'tint_dark'} = $td ? parse_hex_color($td) : [0,0,0];
        } elsif (length($pals) > 42 || $pals =~ /[^0-9a-f]/) {
            return 404;
        } else {
            my $len = length($pals);
            return 404 if $len % 7;  # must be multiple of 7 chars
            for (my $i = 0; $i < $len/7; $i++) {
                my $palindex = hex(substr($pals, $i*7, 1));
                $pal_colors{$palindex} = [
                                          hex(substr($pals, $i*7+1, 2)),
                                          hex(substr($pals, $i*7+3, 2)),
                                          hex(substr($pals, $i*7+5, 2)),
                                          substr($pals, $i*7+1, 6),
                                          ];
            }
        }
    }

    if (%pal_colors) {
        if ($type eq 'gif') {
            return 404 unless PaletteModify::new_gif_palette($data, \%pal_colors);
        } elsif ($type eq 'png') {
            return 404 unless PaletteModify::new_png_palette($data, \%pal_colors);
        }
    }

    # success
    return 0;
}
####### PALIMG END #############################################################################

####### PALETTEMODIFY START ####################################################################
package PaletteModify;

BEGIN {
    $PaletteModify::HAVE_CRC = eval "use String::CRC32 (); 1;";
}

sub common_alter
{
    my ($palref, $table) = @_;
    my $length = length $table;

    my $pal_size = $length / 3;

    # tinting image?  if so, we're remaking the whole palette
    if (my $tint = $palref->{'tint'}) {
        my $dark = $palref->{'tint_dark'};
        my $diff = [ map { $tint->[$_] - $dark->[$_] } (0..2) ];
        $palref = {};
        for (my $idx=0; $idx<$pal_size; $idx++) {
            for my $c (0..2) {
                my $curr = ord(substr($table, $idx*3+$c));
                my $p = \$palref->{$idx}->[$c];
                $$p = int($dark->[$c] + $diff->[$c] * $curr / 255);
            }
        }
    }

    while (my ($idx, $c) = each %$palref) {
        next if $idx >= $pal_size;
        substr($table, $idx*3+$_, 1) = chr($c->[$_]) for (0..2);
    }

    return $table;
}

sub new_gif_palette
{
    my ($data, $palref) = @_;

    # make sure we have data to operate on, or the substrs below die
    return unless $$data;

    # 13 bytes for magic + image info (size, color depth, etc)
    # and then the global palette table (3*256)
    my $header = substr($$data, 0, 13+3*256);

    # figure out how big global color table is (don't want to overwrite it)
    my $pf = ord substr($header, 10, 1);
    my $gct = 2 ** (($pf & 7) + 1);  # last 3 bits of packaged fields

    # final sanity check for size so the substr below doesn't die
    return unless length $header >= 13 + 3 * $gct;

    substr($header, 13, 3*$gct) = common_alter($palref, substr($header, 13, 3*$gct));
    $$data = $header;
    return 1;
}

sub new_png_palette
{
    my ($data, $palref) = @_;

    # subroutine for reading data
    my ($curidx, $maxlen) = (0, length $$data);
    my $read = sub {
        # put $_[1] data into scalar reference $_[0]
        return undef if $_[1] + $curidx > $maxlen;
        ${$_[0]} = substr($$data, $curidx, $_[1]);
        $curidx += $_[1];
        return length ${$_[0]};
    };

    # without this module, we can't proceed.
    return 0 unless $PaletteModify::HAVE_CRC;

    my $imgdata;

    # Validate PNG signature
    my $png_sig = pack("H16", "89504E470D0A1A0A");
    my $sig;
    $read->(\$sig, 8);
    return 0 unless $sig eq $png_sig;
    $imgdata .= $sig;

    # Start reading in chunks
    my ($length, $type) = (0, '');
    while ($read->(\$length, 4)) {

        $imgdata .= $length;
        $length = unpack("N", $length);
        return 0 unless $read->(\$type, 4) == 4;
        $imgdata .= $type;

        if ($type eq 'IHDR') {
            my $header;
            $read->(\$header, $length+4);
            my ($width,$height,$depth,$color,$compression,
                $filter,$interlace, $CRC)
                = unpack("NNCCCCCN", $header);
            return 0 unless $color == 3; # unpaletted image
            $imgdata .= $header;
        } elsif ($type eq 'PLTE') {
            # Finally, we can go to work
            my $palettedata;
            $read->(\$palettedata, $length);
            $palettedata = common_alter($palref, $palettedata);
            $imgdata .= $palettedata;

            # Skip old CRC
            my $skip;
            $read->(\$skip, 4);

            # Generate new CRC
            my $crc = String::CRC32::crc32($type . $palettedata);
            $crc = pack("N", $crc);

            $imgdata .= $crc;
            $$data = $imgdata;
            return 1;
        } else {
            my $skip;
            # Skip rest of chunk and add to imgdata
            # Number of bytes is +4 becauses of CRC
            #
            for (my $count=0; $count < $length + 4; $count++) {
                $read->(\$skip, 1);
                $imgdata .= $skip;
            }
        }
    }

    return 0;
}
####### PALETTEMODIFY END ######################################################################

1;

__END__

=head1 NAME

Perlbal::Plugin::Palimg -  plugin that allows Perlbal to serve palette altered images

=head1 VERSION

This documentation refers to C<Perlbal::Plugin::Palimg> that ships with Perlbal 1.50

=head1 DESCRIPTION

Palimg is a perlbal plugin that allows you to modify C<GIF> and C<PNG> on the fly.  Put the images you want to be able to modify into the C<DOCROOT/palimg/> directory.  You modify them by adding C</pSPEC> to the end of the url, where SPEC is one of the below defined commands (gradient, tint, etc).

=head1 CONFIGURING PERLBAL

To configure your Perlbal installation to use Palimg you'll need to C<LOAD> the plugin then add a service parameter to a C<web_server> service to activate it.

Example C<perlbal.conf>: 
	
    LOAD palimg

    CREATE SERVICE palex
       SET listen         = ${ip:eth0}:80
       SET role           = web_server
       SET plugins        = palimg
       SET docroot        = /usr/share/doc/
       SET dirindexing    = 0
    ENABLE palex

=head1 GRADIENTS

You can change the gradient of the image by adding C</pg0011111164ffffff> to the end of the url.  C<00> is the index where the gradient starts and C<111111> is the color (in hex) of the begining of the gradient.  C<64> is the index of the end of the gradient and C<ffffff> is the color of the end of the gradient.  Note that all colors specified in hex should be lowercase.

Example:

	http://192.168.0.1/palimg/logo.gif/pg01aaaaaa99cccccc

=head1 TINTING 

You can tint the image by adding C</pt000000aaaaaa> to the end of the url.  C<000000> should be replaced with the color to tint towards.  C<aaaaaa> is optional and defines the "dark" tint color.  Both colors should be specified as lowercase hex numbers.  

Example: 

	http://192.168.0.1/palimg/logo.gif/pt1c1c1c22dba1

=head1 PALETTE REPLACEMENT

You can specify a palette to replace the palette of the image.  Do this by adding up to six sets of seven hex lowercase numbers prefixed with C</p> to the end of the URL.

Example: 

	http://192.168.0.1/palimg/logo.gif/p01234567890abcfffffffcccccccddddddd

=head1 BUGS AND LIMITATIONS

There are no known bugs in this module.

Please report problems to the Perlbal mailing list, http://lists.danga.com/mailman/listinfo/perlbal/

Patches are welcome.

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com>
Mark Smith       <junior@danga.com>

=head1 LICENSE AND COPYRIGHT

Artistic/GPLv2, at your choosing.

Copyright 2004, Danga Interactive
Copyright 2005-2006, Six Apart Ltd
