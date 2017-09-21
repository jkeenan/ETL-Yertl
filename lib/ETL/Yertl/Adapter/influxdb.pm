package ETL::Yertl::Adapter::influxdb;
our $VERSION = '0.033';
# ABSTRACT: Adapter to read/write from InfluxDB time series database

=head1 SYNOPSIS

    my $db = ETL::Yertl::Adapter::influxdb->new( 'influxdb://localhost:8086' );
    my @points = $db->read_ts( { metric => 'db.cpu_load.1m' } );
    $db->write_ts( { metric => 'db.cpu_load.1m', value => 1.23 } );

=head1 DESCRIPTION

This class allows Yertl to read and write time series from L<the InfluxDB
time series database|https://www.influxdata.com>.

This adapter is used by the L<yts> command.

=head2 Metric Name Format

InfluxDB has databases, metrics, and fields. In Yertl, the time series
is identified by joining the database, metric, and field with periods (C<.>).
The field is optional, and defaults to C<value>.

    # Database "foo", metric "bar", field "baz"
    yts influxdb://localhost foo.bar.baz

    # Database "foo", metric "bar", field "value"
    yts influxdb://localhost foo.bar

=head1 SEE ALSO

L<ETL::Yertl>, L<yts>,
L<Reading data from InfluxDB|https://docs.influxdata.com/influxdb/v1.3/guides/querying_data/>,
L<Writing data to InfluxDB|https://docs.influxdata.com/influxdb/v1.3/guides/writing_data/>,
L<InfluxDB Query language|https://docs.influxdata.com/influxdb/v1.3/query_language/data_exploration/>

=cut

use ETL::Yertl 'Class';
use Net::Async::HTTP;
use URI;
use JSON::MaybeXS qw( decode_json );
use List::Util qw( first );
use DateTime::Format::ISO8601;
use IO::Async::Loop;

has host => ( is => 'ro', required => 1 );
has port => ( is => 'ro', default => 8086 );

has _loop => (
    is => 'ro',
    default => sub {
        IO::Async::Loop->new();
    },
);

has client => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my ( $self ) = @_;
        my $http = Net::Async::HTTP->new;
        $self->_loop->add( $http );
        return $http;
    },
);

has dt_fmt => (
    is => 'ro',
    lazy => 1,
    default => sub {
        DateTime::Format::ISO8601->new;
    },
);

=method new

    my $db = ETL::Yertl::Adapter::influxdb->new( 'influxdb://localhost' );
    my $db = ETL::Yertl::Adapter::influxdb->new( 'influxdb://localhost:8086' );

Construct a new InfluxDB adapter for the database on the given host and port.
Port is optional and defaults to C<8086>.

=cut

sub BUILDARGS {
    my ( $class, @args ) = @_;
    my %args;
    if ( @args == 1 ) {
        if ( $args[0] =~ m{://([^:]+)(?::([^/]+))?} ) {
            @args{qw( host port )} = ( $1, $2 );
            delete $args{port} if !$args{port};
        }
    }
    else {
        %args = @args;
    }
    return \%args;
}

=method read_ts

    my @points = $db->read_ts( $query );

Read a time series from the database. C<$query> is a hash reference
with the following keys:

=over

=item metric

The time series to read. For InfluxDB, this is the database, metric, and
field separated by dots (C<.>). Field defaults to C<value>.

=item start

An ISO8601 date/time for the start of the series points to return,
inclusive.

=item end

An ISO8601 date/time for the end of the series points to return,
inclusive.

=item tags

An optional hashref of tags. If specified, only points matching all of
these tags will be returned.

=back

=cut

sub read_ts {
    my ( $self, $query ) = @_;
    my $metric = $query->{ metric };
    ( my $db, $metric, my $field ) = split /\./, $metric;
    $field ||= "value";

    my $q = sprintf 'SELECT "%s" FROM "%s"', $field, $metric;
    my @where;
    my $tags = $query->{ tags };
    if ( $tags && keys %$tags ) {
        push @where, map { sprintf q{"%s"='%s'}, $_, $tags->{ $_ } } keys %$tags;
    }
    if ( my $start = $query->{start} ) {
        push @where, qq{time >= '$start'};
    }
    if ( my $end = $query->{end} ) {
        push @where, qq{time <= '$end'};
    }
    if ( @where ) {
        $q .= ' WHERE ' . join " AND ", @where;
    }

    my $url = URI->new( sprintf 'http://%s:%s/query', $self->host, $self->port );
    $url->query_form( db => $db, q => $q );

    #; say "Fetching $url";
    my $res = $self->client->GET( $url )->get;

    #; say $res->decoded_content;
    if ( $res->is_error ) {
        die sprintf "Error fetching metric '%s': " . $res->decoded_content . "\n", $metric;
    }

    my $result = decode_json( $res->decoded_content );
    my @points;
    for my $series ( map @{ $_->{series} }, @{ $result->{results} } ) {
        my $time_i = first { $series->{columns}[$_] eq 'time' } 0..$#{ $series->{columns} };
        my $value_i = first { $series->{columns}[$_] eq $field } 0..$#{ $series->{columns} };

        push @points, map {
            +{
                metric => join( ".", $db, $series->{name}, ( $field ne 'value' ? ( $field ) : () ) ),
                timestamp => $_->[ $time_i ],
                value => $_->[ $value_i ],
            }
        } @{ $series->{values} };
    }

    return @points;
}

=method write_ts

    $db->write_ts( @points );

Write time series points to the database. C<@points> is an array
of hashrefs with the following keys:

=over

=item metric

The metric to write. For InfluxDB, this is the database, metric,
and field separated by dots (C<.>). Field defaults to C<value>.

=item timestamp

An ISO8601 timestamp. Optional. Defaults to the current time on the
InfluxDB server.

=item value

The metric value.

=back

=cut

sub write_ts {
    my ( $self, @points ) = @_;

    my %db_lines;
    for my $point ( @points ) {
        my ( $db, $metric, $field ) = split /\./, $point->{metric};
        my $tags = '';
        if ( $point->{tags} ) {
            $tags = join ",", '', map { join "=", $_, $point->{tags}{$_} } keys %{ $point->{tags} };
        }

        my $ts = '';
        if ( $point->{timestamp} ) {
            $ts = " " . (
                $self->dt_fmt->parse_datetime( $point->{timestamp} )->hires_epoch * 10**9
            );
        }

        push @{ $db_lines{ $db } }, sprintf '%s%s %s=%s%s',
            $metric, $tags, $field || "value",
            $point->{value}, $ts;
    }

    for my $db ( keys %db_lines ) {
        my @lines = @{ $db_lines{ $db } };
        my $body = join "\n", @lines;
        my $url = URI->new( sprintf 'http://%s:%s/write?db=%s', $self->host, $self->port, $db );
        my $res = $self->client->POST( $url, $body, content_type => 'text/plain' )->get;
        if ( $res->is_error ) {
            my $result = decode_json( $res->decoded_content );
            die "Error writing metric '%s': $result->{error}\n";
        }
    }

    return;
}

1;
