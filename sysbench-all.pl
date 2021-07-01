#!/usr/bin/env perl

use strict;
use warnings;

$| = 1;

use Path::Class qw(file dir);
use IPC::Run qw( start pump finish timeout );
use DateTime;
use Time::HiRes qw(gettimeofday tv_interval);

my $dt = DateTime->now();

my $DOCKER_IMAGE = 'severalnines/sysbench';

my $log = $ARGV[0] or die "must supply log output file arg";
my $lFH = file($log)->open('w') or die "Couldn't open $log for write/append";

&_log_print("=== sysbench-all.pl starting at " . $dt->ymd('-') . ' ' . $dt->hms(':') . "===\n\n");

my @cmds = (
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
);



&_run_cmd($_) for (@cmds);

exit;

sub _run_cmd {
  my $cmd = shift;
  my $orig_cmd = $cmd;
  
  
  $cmd =~ s/\\//g;
  $cmd =~ s/\r?\n/ /g;
  
  my @cmd = split(/\s+/,$cmd);
  
  my ($in, $out, $err);
  
  &_log_print("\n(run) --> " . join(' ', @cmd));
  
  my $t0 = [gettimeofday];
  
  my $h = start \@cmd, \$in, \$out, \$err;
  
  my $printed = 0;
  while(pump $h) {
    $printed = 1;
    &_log_print($out) and $out = '' if($out);
    &_log_print($err) and $err = '' if($err);
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


