#!/usr/bin/perl

use strict;
use warnings;
use Date::Parse;
use Date::Calc qw/Delta_Days/;

sub usage {
    return "$0 server database date\nThe script will pick the archive with the
    close date downwards.\n";
}

my $server  = $ARGV[0] || die &usage();
my $db_name = $ARGV[1] || die &usage();
my $date    = $ARGV[2] || die &usage();

my $bac_dir = '/backup/mysql';
my $tmp_dir = '/tmp/';

die "Cannot find $bac_dir/$server/"         if !-d "$bac_dir/$server";
die "Cannot find $bac_dir/$server/Daily/"   if !-d "$bac_dir/$server/Daily";
die "Cannot find $bac_dir/$server/Monthly/" if !-d "$bac_dir/$server/Monthly";

my @access_time  = localtime(Date::Parse::str2time($date));
my $access_year  = $access_time[5] + 1900;
my $access_month = $access_time[4] + 1;
my $access_day   = $access_time[3];

my $dates = &get_dates("$bac_dir/$server/Daily/");
my $cur_archive = q{};
my $is_diff_file = 0;
foreach my $d (@{ $dates }) {
    if (Delta_Days($access_year, $access_month, $access_day, split(q{-}, $d)) <= 0) {
        if (-e "$bac_dir/$server/Daily/$d/$db_name.sql.gz") {
            $cur_archive = "$bac_dir/$server/Daily/$d/$db_name.sql.gz";
            last;
        }
        if (-e "$bac_dir/$server/Daily/$d/$db_name.sql.diff.gz") {
            $cur_archive = "$bac_dir/$server/Daily/$d/$db_name.sql.diff.gz";
            $is_diff_file = 1;
            last;
        }
    }
}
if (!$cur_archive) {
    my $monthly_dates = &get_dates("$bac_dir/$server/Monthly/");
    foreach my $m (@{ $monthly_dates }) {
        if (Delta_Days($access_year, $access_month, $access_day, split(q{-}, $m)) <= 0) {
            if (-e "$bac_dir/$server/Monthly/$m/$db_name.sql.gz") {
                $cur_archive = "$bac_dir/$server/Monthly/$m/$db_name.sql.gz";
                last;
            }
        }
    }
}

if (! $cur_archive ) {
    print "Archive $db_name on $server from $date not found!";
}
else {
    print "Archive found!\n";
    if ($is_diff_file) {
        print "\tUnzipping Monthly ... ";
        my $monthly_dates = &get_dates("$bac_dir/$server/Monthly/");
        my $monthly_archive = q{};
        foreach my $date (@{ $monthly_dates }) {
            if (Delta_Days($access_year, $access_month, $access_day, split(q{-}, $date)) <= 0) {
                if (-e "$bac_dir/$server/Monthly/$date/$db_name.sql.gz") {
                    $monthly_archive = "$bac_dir/$server/Monthly/$date/$db_name.sql.gz";
                    last;
                }
            }
        }
        if ($monthly_archive) {
            print "$monthly_archive\n";
            print "$cur_archive\n";
            `gzip -d -c '$monthly_archive' > '$tmp_dir/$db_name.monthly.sql'`;
            `gzip -d -c '$cur_archive'     > '$tmp_dir/$db_name.sql.diff'`;
            `rdiff patch '$tmp_dir/$db_name.monthly.sql' '$tmp_dir/$db_name.sql.diff' $tmp_dir/$db_name.sql`;
            `rm $tmp_dir/$db_name.monthly.sql`;
            `rm $tmp_dir/$db_name.sql.diff`;
        }
        print "done.\n";
        print "Location is: $tmp_dir/$db_name.sql\n";
    }
    else {
        print "Location is: $cur_archive\n";
    }
}


sub get_dates {
    my $dir = shift;

    opendir(DIR, $dir) or die "Could not open the directory $dir to check for latest date";
    my @dates = ();
    while (my $date = readdir(DIR)) {
        push @dates, $date;
    }
    closedir(DIR);

    # get the latest date
    my @cur_dates = sort { $b cmp $a } # reverse sort them
    #map  { $_ =~ s/[^\d]//g; $_; } # make a numerical date out of year-mm-dd
    grep { ! /\./ } # remove the dot dirs
    @dates;

    return \@cur_dates;
}
