package Koha::Plugin::Com::ByWaterSolutions::Deduplication;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use File::Basename;
use Text::CSV;
use List::Util qw(any);
use List::MoreUtils qw( uniq );
use utf8;
use open qw(:utf8);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Members;
use C4::Auth;
use C4::Biblio;
use C4::Matcher;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::SearchEngine::Indexer;
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
    date_updated    => '1900-01-01',
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
    my @names = $cgi->param;

    if ( $cgi->param('submitted') ) {
        $self->search_step_2();
    }
    elsif ( $cgi->param('merging_time') ) {
        $self->search_step_3();
    }
    else {
        my $template = $self->get_template({ file => 'tool_step_0.tt' });
        print $cgi->header();
        print $template->output();
    } 
}

=head3 upgrade

Takes care of upgrading whatever is needed (table structure, new tables, information on those)

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    # upgrade added after 0.0.11
    my $new_version = "0.0.12";

    if (
        Koha::Plugins::Base::_version_compare(
            $self->retrieve_data('__INSTALLED_VERSION__'), $new_version ) == -1
      )
    {

        my $table = $self->get_qualified_table_name('mytable');

        if ( $self->_table_exists($table) ) {
            C4::Context->dbh->do(qq{
                DROP TABLE $table;
            });
        }

        $self->store_data( { '__INSTALLED_VERSION__' => $new_version } );
    }
}

sub move_step_1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'move_step_1.tt' });

    print $cgi->header();
    print $template->output();
}

sub move_step_2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $template;

    my $filename = $cgi->param("items");
    if( $filename ){
        my ( $name, $path, $extension ) = fileparse( $filename, '.csv' );

        my $csv_contents;
        open my $fh_out, '>', \$csv_contents or die "Can't open variable: $!";

        my $delimiter = $self->retrieve_data('delimiter') || C4::Context->preference('delimiter');
        $delimiter = "\t" if ($delimiter eq 'tabulation');
        my $csv = Text::CSV->new( { binary => 1, sep_char => $delimiter } )
          or die "Cannot use CSV: " . Text::CSV->error_diag();

        my $upload_dir        = C4::Context->temporary_directory;#'/tmp';
        my $upload_filehandle = $cgi->upload("items");
        open( UPLOADFILE, '>', "$upload_dir/$filename" ) or die "$!";
        binmode UPLOADFILE;
        while (<$upload_filehandle>) {
            print UPLOADFILE;
        }
        close UPLOADFILE;
        open my $fh_in, '<', "$upload_dir/$filename" or die "Can't open variable: $!";

        my $column_names = $csv->getline($fh_in);
        my @required_columns = ("itemnumber","biblionumber","target");
        my %existing_columns = map { $_ => 1 } @$column_names;
        if ( any {  !defined $existing_columns{$_}  } @required_columns ){
            close $fh_in;
            $template = $self->get_template({ file => 'move_step_1.tt' });
            $template->param( missing_required_columns => 1 );
            print $cgi->header("text/html;charset=UTF-8");
            print $template->output();
            return;
        }
        $csv->column_names(@$column_names);

        $template = $self->get_template({ file => 'move_step_2.tt' });
        my @planned;
        while ( my $hr = $csv->getline_hr($fh_in) ) {
            push @planned, $hr;
        }

        $csv->eof or $csv->error_diag();
        close $fh_in;
        $template->param(
            planned => \@planned,
        );
    } else {
        $template = $self->get_template({ file => 'move_step_1.tt' });
        $template->param( missing_file => 1 );
    }

    print $cgi->header();
    print $template->output();
}

sub move_step_3 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @itemnumbers = $cgi->multi_param('itemnumber');
    my @biblionumbers = $cgi->multi_param('biblionumber');
    my @targets = $cgi->multi_param('target');

    my @moved;
    my @errors;
    my @index;
    for (my $i = 0; $i < @itemnumbers; $i++) {
        my $target = {
            itemnumber   => $itemnumbers[$i],
            biblionumber => $biblionumbers[$i],
            target       => $targets[$i],
        };
        my ($success, $error) = _move_item($target);
        if( $success ){
            push @moved, $target;
            push @index, ($target->{target},$target->{biblionumber});
        } else {
            $target->{error} = $error;
            push @errors, $target;
        }
    }
    @index = uniq @index;
    my $indexer = Koha::SearchEngine::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
    $indexer->index_records( \@index, "specialUpdate", "biblioserver" ) if @index;
    my $template = $self->get_template({ file => 'move_step_3.tt' });
    $template->param(
        need_confirm => $cgi->param('confirm_move') ? 0 : 1,
        errors  => \@errors,
        success => \@moved,
    );

    print $cgi->header();
    print $template->output();
}

sub search_step_1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'search_step_1.tt' });
    my @matchers = C4::Matcher->GetMatcherList();
    $template->param('matchers'=>\@matchers);

    print $cgi->header();
    print $template->output();
}

sub search_step_2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $display_fields =  _get_display_fields();

    my $template = $self->get_template({ file => 'search_step_2.tt' });

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
    my $check_field = $cgi->param('check_field');
    my $check_subfield = $cgi->param('check_subfield');
    my $check_value = $cgi->param('check_value');

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
            select     => ["biblionumber"],
            join       =>, 'items',
            "group_by" => ["biblionumber"],
            order_by   => 'title'
        });
    my %seen;
    my $stored = {};
    while ( my $cur_item = $matched_items->next ){
        if ( !$seen{$cur_item->biblionumber}++ ) {
            my $record;
            if ( C4::Context->preference('Version') gt '17.060000' ) {
                $record = GetMarcBiblio({ biblionumber => $cur_item->biblionumber });
            } else {
                $record = GetMarcBiblio( $cur_item->biblionumber );
            }
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
                            display_fields => $display_fields,
                            check_field    => $check_field,
                            check_subfield => $check_subfield,
                            check_value    => $check_value,
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


sub search_step_3 {
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

    my $template = $self->get_template({ file => 'search_step_3.tt' });
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
    my $record;
    if ( C4::Context->preference('Version') gt '17.060000' ) {
       $record = GetMarcBiblio({ biblionumber => $biblionumber });
    } else {
       $record = GetMarcBiblio( $biblionumber );
    }
    return {biblionumber=>$biblionumber,pre=>undef,length=>0,display=>["Record not found, indexes may need rebuilding"]} if !$record;
    my $length = length( $record->as_formatted() );
    my $check_field = $params->{check_field};
    my $check_subfield = $params->{check_subfield};
    my $check_value = $params->{check_value};
    my $check_sf = $check_subfield ? [ $check_subfield ] : undef;
    my $checker = _get_sub_or_fields({
            record    =>$record,
            tag       =>$check_field,
            subfields =>$check_sf,
            });
    my $pre_select = 0;
    if ( $check_value ) {
        $pre_select = ${$checker}[0] eq $check_value if $checker && ${$checker}[0];
        #if we are checking against a value make sure we match
    } else {
        $pre_select = 1 if $checker && ${$checker}[0];
        #if no value we are checking for existence of field
    }
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
    my $tag       = $params->{tag};
    my $subfields = $params->{subfields};
    my $record    = $params->{record};
    my @display_fields;
    return unless $record && $tag;

    my @marcfields = $record->field($tag);
    foreach my $marcfield (@marcfields) {
        if ($subfields && scalar @{$subfields}) {
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


#This function takes care of these tables: reserves hold_fill_targets tmp_holdsqueue linktracker
# Returns 1 for success, 0 for failure
sub _move_item {
    my $params = shift;
    my $itemnumber = $params->{itemnumber};
    my $biblionumber = $params->{biblionumber};
    my $target = $params->{target};
    my $dbh = C4::Context->dbh;
    my ( $tobiblioitem ) = $dbh->selectrow_array(q|
        SELECT biblioitemnumber
        FROM biblioitems
        WHERE biblionumber = ?
    |, undef, $target );
    my $return = $dbh->do(q|
        UPDATE items
        SET biblioitemnumber = ?,
            biblionumber = ?
        WHERE itemnumber = ?
            AND biblionumber = ?
    |, undef, $tobiblioitem, $target, $itemnumber, $biblionumber );
    if ($return == 1) {
	    # Checking if the item we want to move is in an order 
        require C4::Acquisition;
        my $order = C4::Acquisition::GetOrderFromItemnumber($itemnumber);
	    if ($order) {
		    # Replacing the biblionumber within the order if necessary
		    $order->{'biblionumber'} = $target;
	        C4::Acquisition::ModOrder($order);
	    }

        # Update reserves, hold_fill_targets, tmp_holdsqueue and linktracker tables
        for my $table_name ( qw( reserves hold_fill_targets tmp_holdsqueue linktracker ) ) {
            $dbh->do( qq|
                UPDATE $table_name
                SET biblionumber = ?
                WHERE itemnumber = ?
            |, undef, $target, $itemnumber );
        }
        return (1, undef);
	} elsif ( $dbh->errstr ){
        return (0, $dbh->errstr);
    } else {
        return (0,"Item not moved (no rows affected)");
    }

}

sub _move_items_and_extras { #this is just lifted from Koha
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
         next if ( $report->{length} == 0 );

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

=head3 _table_exists (helper)

Method to check if a table exists in Koha.

FIXME: Should be made available to plugins in core

=cut

sub _table_exists {
    my ($self, $table) = @_;
    eval {
        C4::Context->dbh->{PrintError} = 0;
        C4::Context->dbh->{RaiseError} = 1;
        C4::Context->dbh->do(qq{SELECT * FROM $table WHERE 1 = 0 });
    };
    return 1 unless $@;
    return 0;
}

1;
