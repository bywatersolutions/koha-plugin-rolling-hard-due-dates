package Koha::Plugin::Com::ByWaterSolutions::RollingHardDueDates;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::DateUtils;
use Koha::Patron::Categories;
use Koha::CirculationRules;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Rolling Hard Due Dates',
    author => 'Kyle M Hall',
    description =>
      'Allows for hard due dates to be updated automaitcally at intervals.',
    date_authored   => '2013-04-10',
    date_updated    => '2013-04-22',
    minimum_version => '3.1000000',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $next_step = $cgi->param('next_step') || 'show';

    if ( $next_step eq 'add' ) {
        $self->add();
    }
    elsif ( $next_step eq 'delete' ) {
        $self->delete();
    }
    elsif ( $next_step eq 'update_now' ) {
        $self->show( $self->update_hard_due_dates() );
    }
    else {
        $self->show();
    }
}

sub show {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('dates');

    my $sql = qq{
        SELECT * FROM $table ORDER BY on_date, hard_due_date
    };
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $hard_due_dates = $sth->fetchall_arrayref( {} );

    my $template = $self->get_template( { file => 'show.tt' } );

    $template->param(
        %$args,
        hard_due_dates => $hard_due_dates,
        categorycodes  => scalar Koha::Patron::Categories->search(),
        itemtypes      => scalar Koha::ItemTypes->search(),,
    );

    print $cgi->header();
    print $template->output();
}

sub add {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('dates');

    my $on_date       = $cgi->param("on_date");
    my $hard_due_date = $cgi->param("hard_due_date");

    my $categorycode = $cgi->param("categorycode") || q{};
    my $itemtype     = $cgi->param("itemtype")     || q{};

    if ( $on_date && $hard_due_date ) {
        $on_date       = dt_from_string($on_date);
        $hard_due_date = dt_from_string($hard_due_date);

        $dbh->do(
            qq{
                INSERT INTO $table ( on_date, hard_due_date, categorycode, itemtype )
                VALUES( ?, ?, ?, ? );
            },
            {},
            $on_date->ymd(),
            $hard_due_date->ymd(),
            $categorycode,
            $itemtype,
        );
    }

    $self->show();
}

sub delete {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('dates');

    my $id = $cgi->param("id");

    my $r = $dbh->do(
        qq{
            DELETE FROM $table WHERE id = ?
        }, {}, $id
    );

    $self->show();
}

sub update_hard_due_dates {
    my ( $self, $args ) = @_;

    my $dbh   = C4::Context->dbh;
    my $table = $self->get_qualified_table_name('dates');

    my $sql = qq{
        SELECT * FROM $table WHERE on_date = CURRENT_DATE()
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $actions = $sth->fetchall_arrayref( {} );

    my $rules_affected  = 0;
    my $issues_affected = 0;

    my $circ_control = C4::Context->preference('CircControl');

    foreach my $action (@$actions) {
        my $categorycode = $action->{'categorycode'} || '%';
        my $itemtype     = $action->{'itemtype'}     || '%';

        $rules_affected += $dbh->do(
            qq{
                UPDATE issuingrules 
                SET hardduedate = ?, hardduedatecompare = ?
                WHERE categorycode LIKE ? AND itemtype LIKE ?
            },
            {},
            $action->{'hard_due_date'},
            '-1',
            $categorycode,
            $itemtype,
        );

        my $sql2 = qq{
            SELECT 
                issues.*, 
                items.itype AS itemtype,
                borrowers.categorycode
            FROM issues
            LEFT JOIN items ON issues.itemnumber = items.itemnumber
            LEFT JOIN borrowers ON issues.borrowernumber = borrowers.borrowernumber
        };
        my $sth2 = $dbh->prepare($sql2);
        $sth2->execute();
        while ( my $issue = $sth2->fetchrow_hashref() ) {
            my $rule = Koha::CirculationRules->get_effective_rules(
                {
                    categorycode => $borrowertype,
                    itemtype     => $itemtype,
                    branchcode   => $branchcode,
                    rules        => [ 'hardduedate', 'hardduedatecompare' ],
                }
            );

            if ( $rule->{hardduedate} ) {
                if ( $rule->{hardduedatecompare} eq '-1' ) {
                    my $date_due = dt_from_string( $issue->{date_due}, 'iso' );
                    my $hard_due_date =
                      dt_from_string( $rule->{hardduedate} . " 23:59:00",
                        'iso' );

                    if ( $date_due->ymd() gt $hard_due_date->ymd() ) {
                        $dbh->do(
                            q{ UPDATE issues SET date_due = ? WHERE borrowernumber = ? AND itemnumber = ? },
                            {},
                            (
                                $hard_due_date->ymd() . " 23:59:00",
                                $issue->{borrowernumber},
                                $issue->{itemnumber}
                            )
                        );

                        $issues_affected++;
                    }
                }
            }
        }
    }

    return {
        rules_affected  => $rules_affected,
        issues_affected => $issues_affected
    };
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'configure.tt' } );

    $template->param( cronjob => $self->mbf_path('cronjob.pl'), );

    print $cgi->header();
    print $template->output();
}

sub install {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('dates');

    return C4::Context->dbh->do(
        qq{
              CREATE TABLE IF NOT EXISTS $table (
              id int(11) NOT NULL AUTO_INCREMENT,
              on_date DATE NOT NULL,
              hard_due_date DATE NOT NULL,
              categorycode varchar(10) NOT NULL DEFAULT '',
              itemtype varchar(10) NOT NULL DEFAULT '',
              PRIMARY KEY (id)
              ) ENGINE = INNODB;
          }
    );
}

sub uninstall {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('dates');

    return C4::Context->dbh->do("DROP TABLE $table");
}

1;
