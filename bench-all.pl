#!/usr/bin/env perl

use strict;
use warnings;

$| = 1;

my $VERSION = 0.002;

use Path::Class qw(file dir);
use IPC::Run qw( start pump finish timeout );
use DateTime;
use Time::HiRes qw(gettimeofday tv_interval);



my $DOCKER_IMAGE = '';

my $log = $ARGV[0] or die "must supply log output file arg";
my $lFH = file($log)->open('w') or die "Couldn't open $log for write/append";

&_log_print("=== bench-all.pl $VERSION starting at " . &_cur_ts . "===\n\n");

&_run_cmd('hostname');
&_run_cmd('uname -a');


# Pull the docker images we know we'll be using first:
&_run_cmd('docker pull severalnines/sysbench');
&_run_cmd('docker pull ljishen/sysbench');
&_run_cmd('docker pull polinux/bonnie');


&_run_bench(
  'hdparm on SITE',
  'hdparm on whatever block device is SBL\'s SITE',
  [
    'hdparm -Tt /dev/disk/by-label/SITE'
  ]
);

&_run_bench(
  'bonnie++ using docker',
  'Standard bonnie++ command using /root/temp/bonnie-tmp',
  [
    'mkdir -p /root/temp/bonnie-tmp',
    'docker run -i --rm \
        -v /root/temp/bonnie-tmp:/workdir \
        polinux/bonnie \
        bonnie++ -d /workdir -u 0:0',
    'rm -rf /root/temp/bonnie-tmp'
  ]
);


&_run_bench(
  'sysbench-fileio-rndrw-01',
  'Sysbench FileIO mode "combined random read/write" 5GB data',
  [
    'mkdir -p /root/temp/sysbench',
    'docker run -i --rm \
        -v /root/temp/sysbench/workdir:/root/workdir \
        ljishen/sysbench \
        /root/results/output_fileio.prof \
        --test=fileio \
        --file-total-size=5G \
        --file-num=64 \
        prepare',
    'docker run -i --rm \
        -v /root/temp/sysbench:/root/results \
        -v /root/temp/sysbench/workdir:/root/workdir \
        ljishen/sysbench \
        /root/results/output_fileio.prof \
        --test=fileio \
        --file-total-size=5G \
        --file-num=64 \
        --file-test-mode=rndrw \
        run',
    'rm -rf /root/temp/sysbench'
  ]
);


&_run_bench(
  'sysbench-sbl-mysql-01',
  'Sysbench MySQL test - works as-is for SBL systems only',
  [
    'echo "drop database sbtest;" | mysql',
    'echo "create database sbtest" | mysql',
    'docker run -i --rm \
        -v /run/mysqld/mysqld.sock:/root/mysqld.sock \
        severalnines/sysbench \
        sysbench \
        --db-driver=mysql \
        --mysql-socket=/root/mysqld.sock \
        --mysql-user=root \
        --tables=24 \
        --table-size=100000 \
        --threads=8 \
        /usr/share/sysbench/oltp_read_write.lua prepare',
    'docker run -i --rm \
        -v /run/mysqld/mysqld.sock:/root/mysqld.sock \
        severalnines/sysbench \
        sysbench \
        --db-driver=mysql \
        --mysql-socket=/root/mysqld.sock \
        --mysql-user=root \
        --tables=24 \
        --table-size=100000 \
        --threads=8 \
        /usr/share/sysbench/oltp_read_write.lua run',
    'echo "drop database sbtest;" | mysql'
  ]
);


&_run_bench(
  'sysbench-sbl-mysql-02',
  'Sysbench time-limited MySQL test - works as-is for SBL systems only',
  [
    'echo "drop database sbtest;" | mysql',
    'echo "create database sbtest" | mysql',
    'docker run -i --rm \
        -v /run/mysqld/mysqld.sock:/root/mysqld.sock \
        severalnines/sysbench \
        sysbench \
        --db-driver=mysql \
        --mysql-socket=/root/mysqld.sock \
        --mysql-user=root \
        --tables=16 \
        --table-size=10000 \
        --threads=8 \
        --time=300 \
        --events=0 \
        --report-interval=1 \
        --rate=40 \
        /usr/share/sysbench/oltp_read_write.lua prepare',
    'docker run -i --rm \
        -v /run/mysqld/mysqld.sock:/root/mysqld.sock \
        severalnines/sysbench \
        sysbench \
        --db-driver=mysql \
        --mysql-socket=/root/mysqld.sock \
        --mysql-user=root \
        --tables=16 \
        --table-size=10000 \
        --threads=8 \
        --time=300 \
        --events=0 \
        --report-interval=1 \
        --rate=40 \
        /usr/share/sysbench/oltp_read_write.lua run',
    'echo "drop database sbtest;" | mysql'
  ]
);



exit;

sub _run_bench {
  my ($name, $desc, $cmds) = @_;
  
  my $t0 = [gettimeofday];
  
  &_log_print("== Running benchmark '$name' at " . &_cur_ts . "==\n");
  &_log_print("== Descritpion: $desc ==\n");
  
  &_run_cmd($_) for (@$cmds);
  
  my $elapsed = sprintf('%.3f',tv_interval($t0)).'s'; 
  
  &_log_print("== Benchmark '$name' ran for $elapsed ==\n============================\n\n");
  

}



sub _cur_ts {
  my $dt = DateTime->now();
  return join(' ',$dt->ymd('-'),$dt->hms(':'));
}

sub _run_cmd {
  my $cmd = shift;
  my $orig_cmd = $cmd;
  
  if($cmd =~ /\|/) {
    &_log_print("`$cmd`");
    qx|$cmd|;
    return;
  }
  
  $cmd =~ s/\\//g;
  $cmd =~ s/\r?\n/ /g;
  
  my @cmd = split(/\s+/,$cmd);
  
  my ($in, $out, $err);
  
  &_log_print("\n(run) --> " . $orig_cmd);
  
  my $t0 = [gettimeofday];
  
  my $h = start \@cmd, \$in, \$out, \$err;
  
  my $printed = 0;
  while(pump $h) {
    &_log_print("\n") unless ($printed);
    $printed = 1;
    &_log_print($out) if ($out);
    &_log_print($err) if ($err); 
    $out = '';
    $err = ''; 
  }
  
  finish $h;
  
  my $elapsed = sprintf('%.3f',tv_interval($t0)).'s';   
  if($printed) {
    &_log_print("\n=== completed in $elapsed ===\n");    
  }
  else {
    &_log_print(" [$elapsed]\n");
  }
  

  #&_log_print("\n\nSTDOUT:\n$out\n\nSTDERR:\n$err\n\n=================\n\n");
}



sub _log_print {
  my @text = @_;
  print $_ and $lFH->print($_) for (@text)
}


