#!/usr/local/bin/perl
package MySQL::Backup;

use strict;
use warnings;
use DBI;
use File::Copy;
use Data::Dumper;
use Smart::Comments;
use Date::Calc qw/Delta_Days Add_Delta_Days/;

### Loading settings ...
my $servers = {
    'hanna'   => { user => 'backup', pass => 'backup!rules' },
    'marissa' => { user => 'backup', pass => 'backup!rules' },
    'erik'    => { user => 'backup', pass => 'backup!rules' },
};
our $bac_dir = '/grp/backup/';
our $tmp_dir = '/tmp';
my $keep_for = 365; # days to keep the backups; the monthly backups will be kept an extra 31 days

my $dir_of = {}; # will get filled with the monthy, daily and current backup dir
my %cur_dates_of = (); # caches every call to find all date-subdirs in a dir
#my $file_of = {}; # will get filled when checking and unzipping (monstly during InnoDB dbs)

# some extensions ..
my $sql     = q{sql};
my $sqldiff = q{sql.diff};
my $zip     = q{gz};
my $zql     = qq{$sql.$zip};

# some perl magic ... run it when not loaded as a module, don't run it for the
# tests ..
# http://www252.pair.com/comdog/mastering_perl/Chapters/18.modulinos.html
&run() unless caller();

=head1
The main sub. Runs only when the modulino is run as a script. Does not run
when loaded as module.
=cut
sub run {
    # main program: just loops over all servers and all dbs, checks if something
    # was modified, if yes dumps them.
    foreach my $server (sort keys %{ $servers }) {
        ### $server
        my ($srvr) = split /\./, $server;

        ### making dirs ...
        $dir_of  = &make_dir_structure($srvr);
        my $is_full = $dir_of->{ full };

        my @dbs = &get_dbs($server);
        foreach my $db ( @dbs ) {
            # next if $db !~ /trost_prod/;
            ### Checking: $db
            if ($is_full || &is_different($db, $srvr)) {
                &make_dump($db, $srvr, $is_full);
            }
            else {
                ### SKIPPED
            }
            ### cleaning up ...
            &clean_up_tmp;
        }
        # general cleanup ..
        &clean_up;

        &del_old_bacs;
    }
    ### DONE!
}

=head1
Get's all db names from a certain server and returns them in a array
$server_name
$username
$password
=cut
sub get_dbs {
    my ($srvr) = @_;

    my $server_settings = $servers->{ $srvr };
    my $user = $server_settings->{ user };
    my $pass = $server_settings->{ pass };

    my $dbh = DBI->connect("DBI:mysql:host=$srvr;post=3306", $user, $pass, { RaiseError => 1});
    return sort map { $_->[0] } @{ $dbh->selectall_arrayref("SHOW DATABASES") };
}

=head1
Checks if a db has been modified since last backup.
# for MyISAM dbs:
    - check the update_time in with the query: SHOW TABLE STATUS FROM $db
# for InnoDB:
    - compare the previous dump with current one
    OR
    - compare the previous reassembled dump with the current dump
=cut
sub is_different {
    my ($db, $srvr) = @_;

    my $server_settings = $servers->{ $srvr };
    my $user = $server_settings->{ user };
    my $pass = $server_settings->{ pass };

    my $dbh = DBI->connect("DBI:mysql:host=$srvr;post=3306", $user, $pass, { RaiseError => 1});
    my $sql = "SHOW TABLE STATUS FROM `$db`";
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    
    my $date = &find_previous_archive_date($dir_of->{ daily }, "$db.$zql")
            || &find_previous_archive_date($dir_of->{ daily }, "$db.$sqldiff")
            || &find_previous_archive_date($dir_of->{ monthly }, "$db.$zql")
            || '2000-01-01';
    while (my $row = $sth->fetchrow_hashref) {
        if (!  $row->{'Update_time'}
            || $row->{'Update_time'} eq 'NULL'
        ) {
            ### InnoDB Detected ...
            # InnoDB http://bugs.mysql.com/bug.php?id=14374
            return &_is_diffent_InnoDB;
        }
        elsif (   &cmp_dates($row->{'Update_time'}, $date." 00:00:00") > 0
               || &cmp_dates($row->{'Create_time'}, $date." 00:00:00") > 0
        ) {
            ### Different !
            return 1;
        }
    }

    ### Not different !
    return 0;
}

sub _is_diffent_InnoDB {
    my ($db, $srvr) = @_;

    # find the prev archive..
    my $prev_archive = &find_previous_archive($dir_of->{ daily }, "$db.$sqldiff.$zip")
        || &find_previous_archive($dir_of->{ daily }, "$db.$zql")
        || &find_previous_archive($dir_of->{ monthly }, "$db.$zql");

    # no archive found, definitely different
    if (! $prev_archive) { return 1; }

    my $return = 0;
    my $tmp_diff_dir = &mktemp();
    if ($prev_archive =~ /$sqldiff/) {
        ### diff archive found ...
        my $prev_monthly    = &find_previous_archive($dir_of->{ monthly }, "$db.$zql");         
        my $patched_archive = &patch($prev_monthly, $prev_archive , { dest => "$tmp_diff_dir/$db.patched.sql" });
        my $cur_archive     = &make_full_dump($db, $srvr, { dest => "$tmp_diff_dir/$db.cur.$sql" });

        my $diff = &make_diff($patched_archive, $cur_archive, { dest => "$tmp_diff_dir/$db.diff.sql", report => 1 });
        if ($diff) {
            ### Different !
            $return = 1;
        }
    }
    else {
        ### a normal archive found ...
        if ($prev_archive =~ /\.$zip$/) { 
            `gunzip -d -c $prev_archive > $tmp_diff_dir/$db.$sql`;
        }
        else {
            move($prev_archive, "$tmp_diff_dir/$db.$sql");
        }
        my $cur_archive = &make_full_dump($db, $srvr, { dest => "$tmp_diff_dir/$db.cur.$sql" });
        my $diff        = &make_diff("$tmp_diff_dir/$db.$sql", $cur_archive, { dest => "$tmp_diff_dir/$db.$sqldiff", report => 1 });
        if ($diff) {
            ### $diff
            $return = 1;
        }
    }

    &clean_up_tmp($tmp_diff_dir, { remove => 1 });
    return $return;
}

=head1
Patches an archive.
$archive full path to archive
$patch full path to patch
$options: {
 dest => destination_file_name, # optional destination file name, otherwise
$tmp_dir/$db.patched.sql
 remove => 0 # remove the diff and original archive? default: 1
}
=cut
sub patch {
    my ($archive, $patch, $options) = @_;

    my ($db_ext)   = reverse split /\//, $archive; # beware that this also preserves the extension!
    my $dest   = $options->{ dest }   || "$tmp_dir/$db_ext.patched.sql";
    my $remove = $options->{ remove } || 1;

    my $tmp_patch_dir = &mktemp();
    if ($archive =~ /\.$zip$/) { 
        `gunzip -d -c $archive > $tmp_patch_dir/$db_ext.$sql`;
    }
    else {
        move($archive, "$tmp_patch_dir/$db_ext.$sql");
    }
    if ($patch =~ /\.$zip$/) { 
        `gunzip -d -c $patch > $tmp_patch_dir/$db_ext.$sqldiff`;
    }
    else {
        move($patch, "$tmp_patch_dir/$db_ext.$sqldiff");
    }

    `rdiff patch $tmp_patch_dir/$db_ext.$sql $tmp_patch_dir/$db_ext.$sqldiff $dest`;
    if ($remove) {
        no warnings;
        
        opendir D, $tmp_patch_dir;
        map { unlink "$tmp_patch_dir/$_" } readdir D;
        closedir D;

        rmdir("$tmp_patch_dir");
    }

    return $dest;
}

=head1
Finds the previous archive and returns the path+filename
$start_dir
$file_name
=cut
sub find_previous_archive {
    my ($start_dir, $file_name) = @_;
    my $date = &find_previous_archive_date;

    return "$start_dir/$date/$file_name" if $date;
    return 0;
}

sub find_previous_archive_date {
    my ($start_dir, $file_name) = @_;

    # open up the psbsqlXX/Daily dir ..
    opendir(DR, $start_dir) or warn "Could not open the directory $start_dir to find the previous archive\n";
    my @dirs = ();
    while (my $dir = readdir(DR)) {
        push @dirs, $dir;
    }
    closedir(DR);
    
    my @dates = sort { $b <=> $a }            # reverse sort them
                map  { $_ =~ s/[^\d]//g; $_ } # make a numerical date out of year-mm-dd
                grep { ! /\./ }               # remove the dot dirs
                @dirs;

    # check if the archive exists ..
    foreach my $date (@dates) {
        $date =~ s/(\d{4})(\d{2})(\d{2})/$1-$2-$3/;
        return $date if -e "$start_dir/$date/$file_name";
    }

    return 0;
}

=head1
Determines what kind of dump to make and makes the MySQL dump
$db
$srvr
$is_full
=cut
sub make_dump {
    my ($db, $srvr, $is_full) = @_;

    my $dest = q{};
    my $latest_monthly = $dir_of->{ monthly } . '/' . &get_latest_date($dir_of->{ monthly });
    if ($is_full || !-e $latest_monthly . "/$db.$zql") {
        $dest = &make_full_dump($db, $srvr, { zip => 1 });

        if (!-e $latest_monthly .  "/$db.$zql") {
            ### First dump! Moving archive to monthly ...
            move($dest, "$latest_monthly/$db.$zql" );
            return "$latest_monthly/$db.$zql";
        }
    }
    else {
        $dest = &make_diff_dump($db, $srvr, { zip => 1 });
    }

    move($dest, $dir_of->{ current });
    return $dir_of->{ current } . "/$db.$sqldiff.$zip";
}

=head1
Makes a complete MySQL dump, and zips them on demand
$db
$srvr
$options: {
 zip => 0|1 # zip the dumped archive? default 0
 dest => destination_file_name # optional destination file name, otherwise
$tmp/dir/$db.cur.sql
=cut
sub make_full_dump {
    ### FULL DUMP
    my ($db, $srvr, $options) = @_;
    my $zipit = $options->{ zip }  || 0;
    my $dest  = $options->{ dest } || "$tmp_dir/$db." . ( $zipit ? $zql : $sql );

    my $user = $servers->{$srvr}->{user};
    my $pass = $servers->{$srvr}->{pass};

    $pass =~ s/\$/\\\$/g;
    my $command = "mysqldump -u $user -e -p$pass -h $srvr --skip-comments $db";
    $command   .= $zipit ? "| pigz -9 > '$dest'"
                         :          " > '$dest'";

    # execute
    `$command`;

    return $dest;
}

=head1
Makes a diff MySQL dump, and zips them on demand
A diff dump compares with the previous dump and saves the differences
$options: {
 zip => 0|1 # zip the dumped archive? default 0
 dest => destination_file_name # optional destination file name, otherwise
$tmp/dir/$db.sql.diff
=cut
sub make_diff_dump {
    ### DIFF DUMP
    my ($db, $srvr, $options) = @_;
    
    my $zipit = $options->{ zip } || 0;
    my $dest  = $options->{ dest } || "$tmp_dir/$db.$sqldiff";

    # find the prev monthly archive..
    my $prev_archive = &find_previous_archive($dir_of->{ monthly }, "$db.$zql");
    if ($prev_archive =~ /\.$zip$/) {
        `gunzip -d -c $prev_archive > $tmp_dir/$db.$sql`;
    }
    else {
        move($prev_archive, "$tmp_dir/$db.$sql");
    }
    my $cur_archive  = &make_full_dump($db, $srvr, { dest => "$tmp_dir/$db.cur.$sql" });
    my $diff         = &make_diff("$tmp_dir/$db.$sql", $cur_archive, { dest => $dest , zip => 1 });

    my ($diff_file) = reverse split /\//, $diff;

    move($diff, $dir_of->{ current } . "/$diff_file");
}

=head1
Make a diff between two archives ..
$arch1
$arch2
$options
 dest => destination for the diff # no default! (too lazy here ;))
=cut
sub make_diff {
    my ($arch1, $arch2, $options) = @_;

    my $zipit  = $options->{ zip  } || 0;
    my $dest   = $options->{ dest } . ($zipit ? ".$zip" : q{});
    my $report = $options->{ report } || 0;

    if ($report) {
        my $diff = `diff -q $arch1 $arch2`;
        return $diff;
    }
    else {
        my $command  = "rdiff signature $arch1 | rdiff delta -- - $arch2 ";
        $command .= $zipit ? " | pigz -9 > $dest"
                           : $dest;
        `$command`;
        return $dest;
    }
}

=head1
Makes all directories necessary for the script to function
$bac_dir/$srvr
              /Daily
                    /$cur_date
              /Monthly
                      /$cur_date

The last dir is only created if the sub detects it's a new month.

Returns a hash:
{
    monthly => $path,
    daily   => $path, 
    current => $path,
    full    => 1|0
}
=cut
sub make_dir_structure {
    my $srvr = shift;

    my $cur_date = &get_date;

    my $monthly_dir = "$bac_dir/$srvr/Monthly";
    my $daily_dir   = "$bac_dir/$srvr/Daily";

    mkdir("$bac_dir/$srvr") if (!-d "$bac_dir/$srvr");
    mkdir($daily_dir)       if (!-d $daily_dir);
    mkdir($monthly_dir)     if (!-d $monthly_dir);

    my $full_bac = -1;
    if (&is_dir_empty($daily_dir) && &is_dir_empty($monthly_dir)) {
        $full_bac = 1;
    }
    if (&is_dir_empty($daily_dir) && !&is_new_month($monthly_dir, $cur_date)) { # daily dir is empty and monthly doesn't differ
        $full_bac = 0;
    }

    ### $full_bac

    if ($full_bac == -1) {
        $full_bac = &is_new_month($monthly_dir, $cur_date);
    }

    my $daily_bac_dir   = "$daily_dir/$cur_date";
    my $monthly_bac_dir = "$monthly_dir/$cur_date";
    my $cur_bac_dir = $daily_bac_dir; 
    if ($full_bac) {
        ### FULL backup !
        $cur_bac_dir = $monthly_bac_dir;
    }
    mkdir($cur_bac_dir) if (!-d $cur_bac_dir);
    mkdir($tmp_dir)     if (!-d $tmp_dir);

    return {
        monthly     => $monthly_dir,
        daily       => $daily_dir,
        current     => $cur_bac_dir,
        cur_date    => $cur_date,
        cur_monthly => "$monthly_dir/$cur_date",
        cur_daily   => "$daily_dir/$cur_date",
        full        => $full_bac,
    }
}

sub is_dir_empty {
    my ($path) = @_;

    opendir DIR, $path;
    while(my $entry = readdir DIR) {
        next if($entry =~ /^\.\.?$/);
        closedir DIR;

        return 0;
    }
    closedir DIR;

    return 1;
}

sub del_old_bacs {
    ### Deleting old backups ... 
    my $daily = $dir_of->{ daily };
    my $monthly = $dir_of->{ monthly };
    my $earliest_date        = get_earliest_date($daily);
    my $second_earliest_date = get_earliest_date($daily, 1);

    # don't delete no nothing if no dailies found.
    if ($earliest_date && $second_earliest_date) {
        `find $daily/$earliest_date -type f -exec cp '{}' $daily/$second_earliest_date \\;`; # copy all current db's to the next date just in case they were ommited  in the second earliest date because of lack of change
        if (Delta_Days(split(q{-}, $earliest_date), split(q{-}, &get_date)) > $keep_for) {
            no warnings;
            opendir DIR, "$daily/$earliest_date/";
            map { unlink "$daily/$earliest_date/" . $_ } readdir DIR;
            closedir DIR;
            rmdir("$daily/$earliest_date");
        }
        my $monthly_keep_for = $keep_for + 31;
        `find $monthly -type d -ctime +$monthly_keep_for -exec rm -Rf '{}' \\;`;
    }
}

=head1
Returns the current date formatted as YYYY-MM-DD
=cut
sub get_date {
    my $Dd = shift || 0;
    my ($sec, $min, $hour, $day, $month, $year) = localtime(time);
    $year += 1900;
    $month++;

    ($year, $month, $day) = Add_Delta_Days($year, $month, $day, $Dd);

    $month = "0$month" if $month < 10;
    $day   = "0$day"   if $day   < 10;

    return "$year-$month-$day";
}

=head1
Gets all date-subdirs of a dir
=cut
sub get_dates {
    my $dir = shift;
    return $cur_dates_of{ $dir } if exists $cur_dates_of{ $dir } && ! @#{ $cur_dates_of{ $dir } };

    opendir(DIR, $dir) or die "Could not open the directory $dir to check for latest date";
    my @dates = ();
    while (my $date = readdir(DIR)) {
        push @dates, $date;
    }
    closedir(DIR);

    # get the latest date
    my @cur_dates = sort { $b <=> $a } # reverse sort them
             map  { $_ =~ s/[^\d]//g; $_; } # make a numerical date out of year-mm-dd
             grep { ! /\./ } # remove the dot dirs
             @dates;

    $cur_dates_of{ $dir } = \@cur_dates;

    return \@cur_dates;
}

=head1
Gets the latest date-subdir in a dir
$dir
=cut
sub get_latest_date {
    (my $date) = @{ &get_dates };

    $date =~ m/(\d{4})(\d{2})(\d{2})/;

    return "$1-$2-$3";
}

sub get_earliest_date {
    my $dir = shift;
    my $which = shift || 0;
    my @dates = reverse @{ &get_dates($dir) };
    my $date = $dates[ $which ];

    return 0 if ! $date; # no date found

    # just in case we need to give a default date instead, this is the code
    #if ( ! $date) {
    #    $date = get_date( -($keep_for + 31) ); # give a default date in case none is found
    #}
    #else {
    #    $date =~ m/(\d{4})(\d{2})(\d{2})/;
    #    $date = "$1-$2-$3";
    #}

    $date =~ m/(\d{4})(\d{2})(\d{2})/;
    $date = "$1-$2-$3";

    return $date;
}

sub cmp_dates {
    my ($date1, $date2) = @_;

    $date1 =~ s/[^\d]//g;
    $date2 =~ s/[^\d]//g;

    # if no date is left, return
    if (! $date1 || ! $date2) {
        return 1;
    }

    return $date1 <=> $date2;
}

=head1
Checks if it's a new month since last backup
=cut
sub is_new_month {
    my ($dir, $cur_date) = @_;
    opendir(DIR, $dir) or die "Could not open the directory $dir";
    my @dates = ();
    while (my $date = readdir(DIR)) {
        push @dates, $date;
    }
    closedir(DIR);

    # get last date
    my ($date) = sort { $b <=> $a }            # reverse sort them
                 map  { $_ =~ s/[^\d]//g; $_ } # make a numerical date out of year-mm-dd
                 grep { ! /\./ }               # remove the dot dirs
                 @dates;

    ### $date;
    return 1 if ! $date; # no prev dir/dates have been found!

    $date =~ m/.{4}(\d{2}).{2}/;
    my $month = $1;

    $cur_date =~ m/.{4}(\d{2}).{2}/;
    my $cur_month = $1;

    return 1 if $month != $cur_month;
    return 0;
}

=head1
Deletes the leftover db's
=cut
sub clean_up_tmp {
    local $tmp_dir = shift || $tmp_dir;
    my $options    = shift || {};

    my $remove = $options->{ remove } || 0;

    opendir(D, $tmp_dir);
    map { unlink "$tmp_dir/$_" } readdir D;
    closedir D;

    if ($remove) {
        no warnings;
        rmdir $tmp_dir;
    }
}

sub clean_up {
    &clean_up_tmp();
    {
        no warnings;
        rmdir($dir_of->{ cur_daily });
    }
}

sub mktemp {
    my @chars = ('a'..'z','A'..'Z','0'..'9', '_');
    my $str = q{};
    for (1..8) {
        $str .= $chars[ rand @chars ];
    }
    mkdir("$tmp_dir/$str");
    return "$tmp_dir/$str";
}

1;
