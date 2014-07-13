package App::YAML::Filter::RecDescent;
# ABSTRACT: A Parse::RecDescent-based parser for programs

use App::YAML::Filter::Base;
use boolean qw( :all );
use Parse::RecDescent;

$::RD_HINT = 1;

my $grammar = q{
    {
        sub one { return is_list( $_[0] ) ? $_[0]->[0] : $_[0] }
        sub is_list { return ref $_[0] eq 'list' }
        sub flatten { map { is_list( $_ ) ? @$_ : $_ } @_ }
        sub list { return bless [ flatten( @_ ) ], 'list' }
        sub empty { return bless {}, 'empty' }
    }

    program: statement ( comb statement )(s?)
        {
            use Data::Dumper;
            yq::diag( 1, "Program: " . Dumper( \@item ) );
            $return = list( $item[1] );
        }

    statement: conditional | expr
        {
            use Data::Dumper;
            yq::diag( 1, "Statement: " . Dumper( \@item ) );
            $return = $item[1];
        }

    conditional: 'if' expr 'then' expr ( 'else' expr )(?)
        {
            use Data::Dumper;
            yq::diag( 1, "Conditional: " . Dumper( \@item ) );
            $return = list( one( $item[2] ) ? $item[4] : $item[5][0] );
        }

    expr: function_call | hash | array | binop | filter | quote_string | number | word
        {
            $return = list( $item[1] );
            use Data::Dumper;
            yq::diag( 1, "Expr: " . Dumper( \@item ) );
        }

    filter: '.' <skip:""> filter_part(s? /[.]/)
        {
            use Data::Dumper;
            yq::diag( 1, "Filter: " . Dumper( \@item ) );
            my @keys = @{$item[3]};
            $return = list( $::document );
            for my $key ( @keys ) {
                yq::diag( 1, "Key: " . Dumper( $key ) );
                if ( $key =~ /^\[\]$/ ) {
                    $return = list( @{ $return->[0] } );
                }
                elsif ( $key =~ /^\[(\d+)\]$/ ) {
                    $return = list( $return->[0][ $1 ] );
                }
                elsif ( $key =~ /^\w+$/ ) {
                    $return = list( $return->[0]{ $key } );
                }
                else {
                    die "Invalid filter key '$key'";
                }
            }
            # Make RD commit to this if the filter is just '.'
            $return;
        }

    filter_part: word | '[' number(?) ']'
        {
            if ( $item[1] eq '[' ) {
                $return = join "", $item[1], @{$item[2]}, $item[3];
            }
            else {
                $return = $item[1];
            }
        }

    binop: (filter|quote_string|number|word) op (filter|quote_string|number|word)
        {
            use Data::Dumper;
            yq::diag( 1, "Binop: " . Dumper( [ one($item[1]), $item[2], one($item[3]) ] ) );
            use boolean qw( true false );
            my ( $lhs_value, $cond, $rhs_value ) = ( one($item[1]), $item[2], one($item[3]) );
            # These operators suppress undef warnings, treating undef as just
            # another value. Undef will never be treated as '' or 0 here.
            if ( $cond eq 'eq' ) {
                $return = defined $lhs_value == defined $rhs_value
                    && $lhs_value eq $rhs_value ? true : false;
            }
            elsif ( $cond eq 'ne' ) {
                $return = defined $lhs_value != defined $rhs_value
                    || $lhs_value ne $rhs_value ? true : false;
            }
            elsif ( $cond eq '==' ) {
                $return = defined $lhs_value == defined $rhs_value
                    && $lhs_value == $rhs_value ? true : false;
            }
            elsif ( $cond eq '!=' ) {
                $return = defined $lhs_value != defined $rhs_value
                    || $lhs_value != $rhs_value ? true : false;
            }
            # These operators allow undef warnings, since equating undef to 0 or ''
            # can be a cause of problems.
            elsif ( $cond eq '>' ) {
                $return = $lhs_value > $rhs_value ? true : false;
            }
            elsif ( $cond eq '>=' ) {
                $return = $lhs_value >= $rhs_value ? true : false;
            }
            elsif ( $cond eq '<' ) {
                $return = $lhs_value < $rhs_value ? true : false;
            }
            elsif ( $cond eq '<=' ) {
                $return = $lhs_value <= $rhs_value ? true : false;
            }
            $return = list( $return );
        }

    function_call: function_name arguments(?)
        {
            use Data::Dumper;
            yq::diag( 1, "FCall: " . Dumper( \@item ) );
            my $func = $item[1];
            my $args = $item[2];
            if ( $func eq 'empty' ) {
                if ( @$args ) {
                    warn "empty does not take arguments\n";
                }
                $return = list( empty );
            }
            elsif ( $func eq 'select' || $func eq 'grep' ) {
                if ( !@$args ) {
                    warn "'$func' takes an expression argument";
                    $return = list( undef );
                }
                else {
                    $return = one( $args->[0] ) ? list( $::document ) : list( undef );
                }
            }
            elsif ( $func eq 'group_by' ) {
                push @{ $::scope->{ group_by }{ one( $args->[0] ) } }, $::document;
                $return = list( undef );
            }
            elsif ( $func eq 'sort' ) {
                push @{ $::scope->{ sort } }, [ one( @$args ), $::document ];
                $return = list( undef );
            }
            elsif ( $func eq 'keys' ) {
                my $value = @$args ? one( $args->[0] ) : $::document;
                if ( ref $value eq 'HASH' ) {
                    $return = list( [ keys %$value ] );
                }
                elsif ( ref $value eq 'ARRAY' ) {
                    $return = list( [ 0..$#{ $value } ] );
                }
                else {
                    warn "keys() requires a hash or array";
                    $return = list( undef );
                }
            }
            elsif ( $func eq 'length' ) {
                my $value = @$args ? one( $args->[0] ) : $::document;
                if ( ref $value eq 'HASH' ) {
                    $return = list( scalar keys %$value );
                }
                elsif ( ref $value eq 'ARRAY' ) {
                    $return = list( scalar @$value );
                }
                elsif ( !ref $value ) {
                    $return = list( length $value );
                }
                else {
                    warn "length() requires a hash, array, string, or number";
                    $return = undef;
                }
            }
        }

    hash: '{' pair(s /,/) '}'
        {
            use Data::Dumper;
            yq::diag( 1, "Hash: " . Dumper \@item );
            $return = {};
            for my $i ( @{$item[2]} ) {
                $return->{ one( $i->[0] ) } = one( $i->[1] );
            }
            $return = list( $return );
        }

    array: '[' expr(s /,/) ']'
        {
            use Data::Dumper;
            yq::diag( 1, "Array: " . Dumper( \@item ) );
            $return = [ flatten( @{ $item[2] } ) ];
        }

    arguments: '(' expr(s /,/) ')'
        {
            $return = list( @{ $item[2] } );
            use Data::Dumper;
            yq::diag( 1, "Args: " . Dumper( \@item ) );
        }

    pair: key ':' expr
        { $return = [ @item[1,3] ] }

    key: filter | quote_string | word

    quote_string: quote non_quote quote
        { $return = eval join "", @item[1..$#item] }

    number: binnum | hexnum | octnum | float | int
        {
            use Data::Dumper;
            yq::diag( 1, "number: " . Dumper \@item );
        }

    binnum: /0b[01]+/
        {
            $return = eval $item[1];
            use Data::Dumper;
            yq::diag( 1, "binnum: " . Dumper \@item );
        }

    hexnum: /0x[0-9A-Fa-f]+/
        {
            $return = eval $item[1];
            use Data::Dumper;
            yq::diag( 1, "hexnum: " . Dumper \@item );
        }

    octnum: /0o?\d+/
        {
            $return = eval $item[1];
            use Data::Dumper;
            yq::diag( 1, "octnum: " . Dumper \@item );
        }

    float: /-?\d+(?:[.]\d+)?(?:e\d+)?/
        {
            $return = $item[1];
            use Data::Dumper;
            yq::diag( 1, "float: " . Dumper \@item );
        }

    int: /-?\d+/

    word: /\w+/

    quote: /(?<!\\\\)['"]/

    non_quote: /(?:[^'"]|(?<=\\\\)['"])+/

    function_name: "empty" | "select" | "grep" | "group_by" | "keys" | "length" | "sort"

    op: "eq" | "ne" | "==" | "!=" | ">=" | ">" | "<=" | "<"

    comb: ',' | '|'
};

my $parser = Parse::RecDescent->new( $grammar );

sub is_list {
    return ref $_[0] eq 'list';
}

sub filter {
    my ( $class, $filter, $doc, $scope ) = @_;
    $yq::VERBOSE = 1;
    $::document = $doc;
    $::scope = $scope;
    my $output = $parser->program( $filter );
    ; use Data::Dumper;
    ; print "Want array: " . wantarray;
    ; print "OUTPUT: " . Dumper $output;
    ; print "SCOPE: " . Dumper $scope;
    if ( wantarray && is_list( $output ) ) {
        return @$output;
    }
    elsif ( is_list( $output ) ) {
        return $output->[-1];
    }
    else {
        return $output;
    }
}

1;
