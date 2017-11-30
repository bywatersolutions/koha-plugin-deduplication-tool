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
use C4::Items;
use C4::Serials;
use C4::Reserves qw/MergeHolds/;
use C4::Acquisition;

## Here we set our plugin version
our $VERSION = "{VERSION}";

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
    my @matchers = C4::Matcher->GetMatcherList();
    $template->param('matchers'=>\@matchers);

    print $cgi->header();
    print $template->output();
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $display_fields =  _get_display_fields();

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
    my $matcher = $cgi->param('matcher');

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
    my $matched_items = Koha::Biblios->search($filter, { 
            join       =>, 'items',
            "group_by" => ["biblionumber"],
            order_by   => 'title'
        });
    my %seen;
    my $stored = {};
    while ( my $cur_item = $matched_items->next ){
        if ( !$seen{$cur_item->biblionumber}++ ) {
            my $record = GetMarcBiblio( $cur_item->biblionumber );
            my $matcher = C4::Matcher->fetch($matcher);
            my @matches = $matcher->get_matches( $record, 100 );
            if ( scalar @matches > 1 ) {
                my $pre_by_value;
                my $pre_by_length;
                my $longest;
                foreach my $match ( @matches ) {
                    $seen{$match->{record_id}}++;
                    my $display_record = _prep_record({
                            biblionumber   => $match->{record_id},
                            display_fields => $display_fields
                        });
                    if ( !$pre_by_value && $display_record->{pre} ) {
                        $pre_by_value = $display_record->{biblionumber};
                        $pre_by_length = $pre_by_value;
                        $longest = $display_record->{length};
                    } elsif ( !$pre_by_length ) {
                        $pre_by_length = $display_record->{biblionumber};
                        $longest = $display_record->{length};
                    } elsif ( $pre_by_value && $display_record->{pre} && $display_record->{length} > $longest ) {
                        $pre_by_value = $display_record->{biblionumber};
                        $pre_by_length = $display_record->{biblionumber};
                        $longest = $display_record->{length};
                    } elsif ( !$pre_by_value && $display_record->{length} > $longest ) {
                        $pre_by_length = $display_record->{biblionumber};
                        $longest = $display_record->{length};
                    }
                        push ( @{$stored->{ $cur_item->biblionumber }->{records}}, $display_record );
                }
                $stored->{ $cur_item->biblionumber }->{preselected} = $pre_by_value || $pre_by_length;
            }
        }
    }

    $template->param( matches => $stored );

    print $cgi->header();
    print $template->output();
}


sub tool_step3 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @biblionumbers;
    my $ref_biblionumber;
    my @report;
    my $display_fields =  _get_display_fields();

    foreach my $merger ( $cgi->multi_param( 'merge' ) ){
        $ref_biblionumber = $cgi->param( 'source'.$merger );
        foreach my $target ( $cgi->multi_param( 'record'.$merger ) ){
            push (@biblionumbers, $target) if $target ne $ref_biblionumber;
        }
        push @report , _merge_biblios({
                ref_biblionumber => $ref_biblionumber,
                biblionumbers    => \@biblionumbers,
                report_fields    => $display_fields
            });
    }

    my $template = $self->get_template({ file => 'tool-step3.tt' });
    $template->param( report => \@report );

    print $cgi->header();
    print $template->output();
}

sub _get_display_fields {
    my $display_fields_str = C4::Context->preference('MergeReportFields') || '245a,020,100a,300,650a,942';
    my @display_fields;
    foreach my $field_str (split /,/, $display_fields_str) {
        if ($field_str =~ /(\d{3})([0-9a-z]*)/) {
            my ($field, $subfields) = ($1, $2);
            push @display_fields, {
                tag => $field,
                subfields => [ split //, $subfields ]
            }
        }
    }
    return \@display_fields;
}


sub _prep_record {
    my $params = shift;
    my $display_fields = $params->{display_fields};
    my $biblionumber = $params->{biblionumber};
    my $record = GetMarcBiblio($biblionumber);
    return {biblionumber=>$biblionumber,pre=>undef,length=>0,display=>["Record not found, indexes may need rebuilding"]} if !$record;
    my $length = length( $record->as_formatted() );
    my $check_field = '942';
    my @check_subfields = ('a');
    my $check_value = 'BK';
    my $checker = _get_sub_or_fields({
            record    =>$record,
            tag       =>$check_field,
            subfields =>\@check_subfields});
    my $pre_select = ${$checker}[0] eq $check_value;
    my @display_record;

    foreach my $field (@$display_fields) {
        my $line = _get_sub_or_fields({
                record    => $record,
                tag       => $field->{tag},
                subfields => $field->{subfields}
            });
        push @display_record, @$line
    }

    return {biblionumber=>$biblionumber,pre=>$pre_select,length=>$length,display=>\@display_record};
}

sub _get_sub_or_fields {
    my $params   = shift;
    my $field     = $params->{field};
    my $tag       = $params->{tag};
    my $subfields = $params->{subfields};
    my $record    = $params->{record};
    my @display_fields;

    my @marcfields = $record->field($tag);
    foreach my $marcfield (@marcfields) {
        if (scalar @{$subfields}) {
            my $subs = join("", @{$subfields} );
            $subs = $marcfield->as_string($subs);
            push @display_fields, $subs;
        } elsif ($tag gt '009') {
                my $value = $marcfield->as_string();
                push @display_fields , $value;
        } else {
             push @display_fields, $marcfield->as_string();
        }
    }
    return \@display_fields
}

sub _move_items_and_extras {
    my $params = shift;
    my $biblionumber = $params->{biblionumber};
    my $ref_biblionumber = $params->{ref_biblionumber};
    my @errors;
    my $dbh = C4::Context->dbh;

    my @notmoveditems;
    # Moving items from the other record to the reference record
    my $items = Koha::Items->search({ biblionumber => $biblionumber });
        while ( my $item = $items->next) {
            my $res = MoveItemFromBiblio( $item->itemnumber, $biblionumber, $ref_biblionumber );
            #This function takes care of these tables: reserves hold_fill_targets tmp_holdsqueue linktracker
            if ( not defined $res ) {
                push @notmoveditems, $item->itemnumber;
            }
        }
    # If some items could not be moved :
    if (scalar(@notmoveditems) > 0) {
        my $itemlist = join(' ',@notmoveditems);
        push @errors, { code => "CANNOT_MOVE", value => $itemlist };
    }

    my $sth_subscription = $dbh->prepare("UPDATE subscription SET biblionumber = ? WHERE biblionumber = ?");
    my $sth_subscriptionhistory = $dbh->prepare("UPDATE subscriptionhistory SET biblionumber = ? WHERE biblionumber = ?");
    my $sth_serial = $dbh->prepare("UPDATE serial SET biblionumber = ? WHERE biblionumber = ?");
    # Moving subscriptions from the other record to the reference record
    my $subcount = CountSubscriptionFromBiblionumber($biblionumber);
    if ($subcount > 0) {
        $sth_subscription->execute($ref_biblionumber, $biblionumber);
        $sth_subscriptionhistory->execute($ref_biblionumber, $biblionumber);
    }
    # Moving serials
    $sth_serial->execute($ref_biblionumber, $biblionumber);
    # Moving orders (orders linked to items of frombiblio have already been moved by MoveItemFromBiblio)
    my @allorders = GetOrdersByBiblionumber($biblionumber);
    my @tobiblioitem = GetBiblioItemByBiblioNumber ($ref_biblionumber);
    my $tobiblioitem_biblioitemnumber = $tobiblioitem [0]-> {biblioitemnumber };
    foreach my $myorder (@allorders) {
        $myorder->{'biblionumber'} = $ref_biblionumber;
        ModOrder ($myorder);
    # TODO : add error control (in ModOrder?)
    }

    # Deleting the other records
    if (scalar(@errors) == 0) {
        # Move holds
        MergeHolds($dbh, $ref_biblionumber, $biblionumber);
        my $error = DelBiblio($biblionumber);
        push @errors, $error if ($error);
    }

    return @errors;

}

sub _merge_biblios {
    my $params = shift;
    my $biblionumbers = $params->{biblionumbers};
    my $ref_biblionumber = $params->{ref_biblionumber};
    my $report_fields = $params->{report_fields};

    my @report_records;

    my @errors;

    foreach my $biblionumber (@$biblionumbers) {

         my $report = _prep_record({biblionumber=>$biblionumber,display_fields=>$report_fields});

         push ( @errors, _move_items_and_extras({biblionumber=>$biblionumber,ref_biblionumber=>$ref_biblionumber}) );
         my $success = (scalar @errors) ? undef : 1;
         my %report_record = (
            biblionumber => $biblionumber,
            ref_biblionumber => $ref_biblionumber,
            fields => $report,
            errors => \@errors,
            success => $success,
        );

        push @report_records, \%report_record;

    }

    return \@report_records;
}




1;
