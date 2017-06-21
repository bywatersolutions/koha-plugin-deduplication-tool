package Koha::Plugin::Com::ByWaterSolutions::Deduplication;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Members;
use C4::Auth;
use C4::Biblio;
use C4::Matcher;
use Koha::Libraries;
use Koha::Patron::Categories;
use MARC::Record;
use Koha::Items;

## Here we set our plugin version
our $VERSION = 0.0;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Deduplication Tool Plugin',
    author => 'Nick Clemens',
    description =>
'This plugin is a helper plugin for deduplication of records within a catalog',
    date_authored   => '2017-06-21',
    date_updated    => '2017-06-21',
    minimum_version => '16.06.00.018',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'tool' subroutine means the plugin is capable
## of running a tool. The difference between a tool and a report is
## primarily semantic, but in general any plugin that modifies the
## Koha database should be considered a tool
sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    if ( $cgi->param('submitted') ) {
        $self->tool_step2();
    }
    elsif ( $cgi->param('merging_time') ) {
        $self->tool_step3();
    }
    else { $self->tool_step1(); }

}

## The existiance of a 'to_marc' subroutine means the plugin is capable
## of converting some type of file to MARC for use from the stage records
## for import tool
##
## This example takes a text file of the arbtrary format:
## First name:Middle initial:Last name:Year of birth:Title
## and converts each line to a very very basic MARC record
sub to_marc {
    my ( $self, $args ) = @_;

    my $data = $args->{data};

    my $batch = q{};

    foreach my $line ( split( /\n/, $data ) ) {
        my $record = MARC::Record->new();
        my ( $firstname, $initial, $lastname, $year, $title ) = split(/:/, $line );

        ## create an author field.
        my $author_field = MARC::Field->new(
            '100', 1, '',
            a => "$lastname, $firstname $initial.",
            d => "$year-"
        );

        ## create a title field.
        my $title_field = MARC::Field->new(
            '245', '1', '4',
            a => "$title",
            c => "$firstname $initial. $lastname",
        );

        $record->append_fields( $author_field, $title_field );

        $batch .= $record->as_usmarc() . "\x1D";
    }

    return $batch;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do( "
        CREATE TABLE  $table (
            `borrowernumber` INT( 11 ) NOT NULL
        ) ENGINE = INNODB;
    " );
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do("DROP TABLE $table");
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step1.tt' });

    print $cgi->header();
    print $template->output();
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-step2.tt' });

    my $filter = {};

    foreach my $p (qw(homebranch holdingbranch location itype ccode notforloan)) {
        if (my @q = $cgi->multi_param($p)) {
            if ($q[0] ne '') {
                my $f = {
                    field => $p,
                    query => \@q,
                };
                if (my $op = scalar $cgi->param($p . '_op')) {
                    $f->{operator} = $op;
                }
                my $cond = { $p => { $f->{operator} =>[ @q ] } };
                 $filter->{$p} = { $f->{operator} =>[ @q ] } ;
            }
        }
    }

    my @c = $cgi->multi_param('c');
    my @fields = $cgi->multi_param('f');
    my @q = $cgi->multi_param('q');
    my @op = $cgi->multi_param('op');

    my $f; 
    for (my $i = 0; $i < @fields; $i++) {
        my $field = $fields[$i];
        my $q = shift @q;
        my $op = shift @op;
        if (defined $q and $q ne '') {
                if (C4::Context->preference("marcflavour") ne "UNIMARC" && $field eq 'publicationyear') {
                    $field = 'copyrightdate';
                }
                $filter->{$field} = { $op => $q };
        }
    }
    my $matched_items = Koha::Items->search($filter, { "group_by" => ["biblionumber"] });
    warn $matched_items->count;
    my %seen;
    my $stored = {};
    while ( my $cur_item = $matched_items->next ){
        if ( !$seen{$cur_item->biblionumber}++ ) {
            my $record = GetMarcBiblio( $cur_item->biblionumber );
            my $matcher = C4::Matcher->fetch(1);
            my @matches = $matcher->get_matches( $record, 100 );
            if ( scalar @matches > 1 ) {
            foreach my $match ( @matches ) {
                if ( 1 || !$seen{$match->{record_id}}++ ){
                    my @display_record = _prep_record({biblionumber=>$match->{record_id}});
                    push ( @{$stored->{ $cur_item->biblionumber }}, \@display_record );
                }
            }
            }
        }
    }


warn Data::Dumper::Dumper( $stored );
    $template->param( matches => $stored );

    print $cgi->header();
    print $template->output();
}


sub tool_step3 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    warn Data::Dumper::Dumper( $cgi->multi_param('merge') );
    foreach my $merger ( $cgi->multi_param('merge') ){
        warn "source:".$cgi->multi_param('source'.$merger);
        warn Data::Dumper::Dumper( $cgi->multi_param('record'.$merger) );
    }

    my $template = $self->get_template({ file => 'tool-step3.tt' });

    print $cgi->header();
    print $template->output();
}

sub _prep_record {
    my $params = shift;
    my $record = GetMarcBiblio($params->{biblionumber});
    my @display_record = ($params->{biblionumber});

    my @display_fields = ('245$a','020','100$a','300','942');
    for my $field ( @display_fields ) {
        my ( $f, $sf ) = split /\$/, $field;
        if ( $f && $sf ) { push ( @display_record, $record->subfield($f,$sf) ); }
        elsif ( $f && !$sf && $record->field($f) ) { push ( @display_record, $record->field($f)->as_formatted() ); }
        else { next; }
    }
    return @display_record;
}




1;
