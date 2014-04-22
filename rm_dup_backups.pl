#!/usr/bin/perl

use strict;
use warnings;

my $bac_dir = '/backup/mysql';
my @servers = qw/server1 server2 server3/

foreach my $server (@servers) {

    print "Checking server $server ...\n";

    opendir(DIR, "$bac_dir/$server/Daily") || die "can't opendir $bac_dir/$server/Daily : $!";
    my @dates = sort
               map  { $_ =~ s/[^\d]//g; $_; } # make a numerical date out of year-mm-dd
               grep { ! /^\./ }
               readdir(DIR);
    closedir DIR;

    # use Data::Dumper;
    #print Dumper \@dirs;

    my $prev_daily = q{};
    foreach my $date (@dates) {
        (my $daily = $date) =~ s/(\d{4})(\d{2})(\d{2})/$1-$2-$3/;
        if (! $prev_daily) { # skip first iteration..
            $prev_daily = $daily;
            next;
        }

        opendir(DATES, "$bac_dir/$server/Daily/$daily");
        my @dbs = grep { ! /^\./ } readdir(DATES);
        closedir(DATES);

        foreach my $dbz (@dbs) {
            if (-e "$bac_dir/$server/Daily/$prev_daily/$dbz") { # if previous db does exist, unzip 'm both and diff 'm
                
                #print "\t$prev_daily/$dbz -- $daily/$dbz\n";

                # unzip 'm both 
                (my $db = $dbz) =~ s/\.gz$//;
                my $prev_bac = "$bac_dir/$server/Daily/$prev_daily/$dbz";
                my $cur_bac  = "$bac_dir/$server/Daily/$daily/$dbz";
                `gunzip -d -c $prev_bac > /tmp/$prev_daily-$db` if !-e "/tmp/$prev_daily-$db";
                `gunzip -d -c $cur_bac  > /tmp/$daily-$db`      if !-e "/tmp/$daily-$db";

                # diff 'm
                my $diff = `diff -q "/tmp/$prev_daily-$db" "/tmp/$daily-$db"`;
                if (!$diff) {
                    warn "$bac_dir/$server/Daily/$daily/$dbz\n"; # print the db path, delete 'm after wards.
                }

                `rm /tmp/$prev_daily-$db`;
                `rm /tmp/$daily-$db`;
            }
        }

        #`rm /tmp/$prev_daily*.sql`;
        $prev_daily = $daily;
    }
}
