#!/usr/local/bin/perl

use lib '../';
use lib '../../';
use Test::More 'no_plan';
use Test::Deep;

use_ok('MySQL::Backup') or exit;
can_ok('MySQL::Backup', 'make_dir_structure');

my $srvr = 'hanna';
&MySQL::Backup::make_dir_structure($srvr);
ok(-d "$MySQL::Backup::bac_dir/$srvr");
ok(-d "$MySQL::Backup::bac_dir/$srvr/Daily");
ok(-d "$MySQL::Backup::bac_dir/$srvr/Monthly");
ok(-d "$MySQL::Backup::tmp_dir");

can_ok('MySQL::Backup', 'is_new_month');
ok(&MySQL::Backup::is_new_month("$MySQL::Backup::bac_dir/$srvr/Daily", "20091330") == 1);

can_ok('MySQL::Backup', 'get_dbs');
#cmp_deeply(&MySQL::Backup::get_dbs($srvr), supersetof('test', 'information_schema', 'mysql'));
cmp_deeply(&MySQL::Backup::get_dbs($srvr), supersetof('a_test'));
