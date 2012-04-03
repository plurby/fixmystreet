package FixMyStreet::SendReport::Open311;

use Moose;
use namespace::autoclean;

BEGIN { extends 'FixMyStreet::SendReport'; }

use FixMyStreet::App;
use mySociety::Config;
use Open311;

sub send {
    return if mySociety::Config::get('STAGING_SITE');
    my $self = shift;
    my ( $row, $h, $to, $template, $recips, $nomail ) = @_;

    my $result = -1;

    foreach my $council ( keys %{ $self->councils } ) {
        my $conf = FixMyStreet::App->model("DB::Open311conf")->search( { area_id => $self->councils->{ $council }, endpoint => { '!=', '' } } )->first;
        #print 'posting to end point for ' . $conf->area_id . "\n" if $verbose;

        # Extra bromley fields
        if ( $row->council =~ /2482/ ) {
            if ( $row->send_fail_count > 0 ) {
                next if bromley_retry_timeout( $row );
            }

            my $extra = $row->extra;
            push @$extra, { name => 'northing', value => $h->{northing} };
            push @$extra, { name => 'easting', value => $h->{easting} };
            push @$extra, { name => 'report_url', value => $h->{url} };
            push @$extra, { name => 'service_request_id_ext', value => $row->id };
            push @$extra, { name => 'report_title', value => $row->title };
            push @$extra, { name => 'public_anonymity_required', value => $row->anonymous ? 'TRUE' : 'FALSE' };
            push @$extra, { name => 'email_alerts_requested', value => 'FALSE' }; # always false as can never request them
            push @$extra, { name => 'requested_datetime', value => $row->confirmed };
            $row->extra( $extra );
        }

        # FIXME: we've already looked this up before
        my $contact = FixMyStreet::App->model("DB::Contact")->find( {
            deleted => 0,
            area_id => $conf->area_id,
            category => $row->category
        } );

        my $open311 = Open311->new(
            jurisdiction => $conf->jurisdiction,
            endpoint     => $conf->endpoint,
            api_key      => $conf->api_key,
        );

        # non standard west berks end points
        if ( $row->council =~ /2619/ ) {
            $open311->endpoints( { services => 'Services', requests => 'Requests' } );
        }

        # required to get round issues with CRM constraints
        if ( $row->council =~ /2218/ ) {
            $row->user->name( $row->user->id . ' ' . $row->user->name );
        }

        my $resp = $open311->send_service_request( $row, $h, $contact->email );

        # make sure we don't save user changes from above
        if ( $row->council =~ /2218/ || $row->council =~ /2482/ ) {
            $row->discard_changes();
        }

        if ( $resp ) {
            $row->external_id( $resp );
            $result *= 0;
            $self->success( 1 )
        } else {
            $result *= 1;
            # temporary fix to resolve some issues with west berks
            if ( $row->council =~ /2619/ ) {
                $result *= 0;
            }
        }
    }

    $self->error( 'Failed to send over Open311' ) unless $self->success;

    return $result;
}

sub bromley_retry_timeout {
    my $row = shift;

    my $tz = DateTime::TimeZone->new( name => 'local' );
    my $now = DateTime->now( time_zone => $tz );
    my $diff = $now - $row->send_fail_timestamp;
    if ( $diff->in_units( 'minutes' ) < 30 ) {
        return 1;
    }

    return 0;
}

1;