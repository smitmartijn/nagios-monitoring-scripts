#!/usr/bin/perl
#
# This script connects to a MySQL of MariaDB database servers and
# gets information about the Galera Cluster (http://galeracluster.com/)
# to use that information to determine the health of the cluster and then
# return the health status in a format that nagios understands.
#
# This script needs a database user, preferbly one with only USAGE rights. Here's an example:
#    GRANT USAGE ON *.* TO 'myuser'@'myhost' IDENTIFIED BY 'mypassword';
#
# EXAMPLE on how to use it in nagios:
#
# define service {
#        host_name db1.local
#        service_description     MySQL - Check Galera Cluster Status
#        check_command           check_galera_status.pl!-h $HOSTADDRESS$ -u myuser -p mypassword --nodes-warn=2 --nodes-crit=1
#        normal_check_interval   5
#        retry_check_interval    1
#        check_period            24x7
#        max_check_attempts      3
#        flap_detection_enabled  1
#        notifications_enabled   1
#        notification_period     24x7
#        notification_interval   60
#        notification_options    c,f,r,u,w
#        contact_groups  hostgroup4_servicegroup49
#        notes   Database - Galera:Checks a Galera Cluster for functionality
#        use     service-global
# }
#
# Martijn Smit <martijn@lostdomain.org>
#
# 06-11-2015: First commit

use strict;
use warnings "all";

use DBI;
use Getopt::Long;
use File::Basename;

my %returnCodes = (
  'OK'       => 0,
  'Warning'  => 1,
  'Critical' => 2,
  'Unknown'  => 3
);

# default values
my $SCRIPTNAME     = basename($0);
my $showHelp       = 0;
my $connectionPort = 3306;
my $connectionHost = 'localhost';
my $connectionUser = '';
my $connectionPassword = '';
my $amountOfNodesWarn  = 2;
my $amountOfNodesCrit  = 1;

sub usage
{
        print <<EOF;

DESCRIPTION

  Nagios script to check if a MySQL/MariaDB Galera Cluster is fully operational.
  This script needs a database user, preferbly one with only USAGE rights. Here's an example:

  GRANT USAGE ON *.* TO 'myuser'\@'myhost' IDENTIFIED BY 'mypassword';

OPTIONS

  --help, -?           Display this help.
  --host=name, -h      Hostname or IP of database server (default $connectionHost).
  --password=name, -p  Password of user to use when connecting to database server.
  --port=#             Port number where database listens to (default $connectionPort).
  --user=name, -u      Check user for connecting to the database server.
  --nodes-warn=#       Turn warning when number of nodes hits this  (default $amountOfNodesWarn).
  --nodes-crit=#       Turn critical when number of nodes hits this (default $amountOfNodesCrit).

EXAMPLE

  When you have 3 nodes and want to get a warning when 1 fails and a critical when 2 fail:

  $SCRIPTNAME --user=myuser --password=mypassword --host=db01.local --port=3306 --nodes-warn=2 --nodes-crit=1

EOF
}

# use Perls GetOptions() to sort of the supplied parameters
my $params = GetOptions(
  'help|?'         => \$showHelp,
  'user|u=s'       => \$connectionUser,
  'password|p=s'   => \$connectionPassword,
  'host|h=s'       => \$connectionHost,
  'port=i'         => \$connectionPort,
  'nodes-warn=i'   => \$amountOfNodesWarn,
  'nodes-crit=i'   => \$amountOfNodesCrit
);

# does the user just want the help page?
if ($showHelp) {
  &usage();
  exit($returnCodes{'OK'});
}

# check parameters
if ($connectionUser eq '') {
  print "Error: Username not provided!\n";
  exit($returnCodes{'Critical'});
}
if ($connectionPassword eq '') {
  print "Error: Password not provided!\n";
  exit($returnCodes{'Critical'});
}
# Nodes not specfied or values out of range (<2 > 64)
if (($amountOfNodesWarn < 1) || ($amountOfNodesWarn > 128)) {
  print "Number Galera Cluster nodes is out of expected range (2...128): $amountOfNodesWarn\n";
  exit($returnCodes{'Critical'});
}
if (($amountOfNodesCrit < 1) || ($amountOfNodesCrit > 128)) {
  print "Number Galera Cluster nodes is out of expected range (2...128): $amountOfNodesCrit\n";
  exit($returnCodes{'Critical'});
}

# the perl option wrapper can report errors
if (!$params) {
  print("Error in parameters. User = $connectionUser, Password=hidden, Host = $connectionHost, Port = $connectionPort");
  exit($returnCodes{'Critical'});
}

# start connecting to the database and executing a SHOW command
my $dsn = "DBI:mysql::host=$connectionHost:port=$connectionPort;mysql_connect_timeout=10";
my $dbh = DBI->connect($dsn, $connectionUser, $connectionPassword, { RaiseError => 0, PrintError => 0, AutoCommit => 0 });

if (DBI::err)
{
  if (DBI::errstr =~ m/Can't connect to/) {
    print("Error during connection: " . DBI::errstr."\n");
    exit($returnCodes{'Critical'});
  }
  if (DBI::errstr =~ m/Access denied for user/) {
    print("User does not have access privileges to database: " . DBI::errstr."\n");
    exit($returnCodes{'Critical'});
  }

  print("Error during connection: " . DBI::errstr."\n");
  exit($returnCodes{'Critical'});
}

# retrieve some of the 'wsrep' status variables to check
my $query = "SHOW GLOBAL STATUS WHERE variable_name in ('wsrep_cluster_size', 'wsrep_cluster_status', 'wsrep_ready', 'wsrep_connected', 'wsrep_local_state_comment', 'wsrep_local_recv_queue_avg')";

# prepare query and check for errors
my $sth = $dbh->prepare($query);
if (DBI::err)
{
  print("Error in preparing query: " . DBI::errstr."\n");
  $dbh->disconnect;
  exit($returnCodes{'Critical'});
}

# execute query and check for errors
$sth->execute();
if ($sth->err)
{
  print("Error in executing query: " . $sth->errstr."\n");
  $dbh->disconnect;
  exit($returnCodes{'Critical'});
}

# retrieve rows into an array and check for errors
my ($key, $value);
$sth->bind_columns(undef, \$key, \$value);
if ($sth->err)
{
  print("Error in binding columns: " . $sth->errstr."\n");
  $sth->finish;
  $dbh->disconnect;
  exit($returnCodes{'Critical'});
}

# loop through results and populate our resulting array
my %results;
while ($sth->fetchrow_arrayref())
{
  $results{$key} = $value;
}

# check for errors while retrieving data
if ($sth->err)
{
  print("Error in fetchting data:" . $sth->err."\n");
  $sth->finish;
  $dbh->disconnect;
  exit($returnCodes{'Critical'});
}

# disconnect database
$sth->finish;
$dbh->disconnect;

# start checking the results
if (!defined($results{'wsrep_cluster_status'}))
{
  print "Warning: It looks like this is not a MySQL/MariaDB Galera cluster. The variable wsrep_cluster_status is not defined.\n";
  exit($returnCodes{'Warning'});
}

# check for node status, this needs to be Primary if it's functional
if ($results{'wsrep_cluster_status'} ne "Primary")
{
  print "Critical: Node is not Primary: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Critical'});
}

# check whether the node is ready
if ($results{'wsrep_ready'} ne "ON")
{
  print "Critical: Node is not ready: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Critical'});
}

# check if the node is connected to others
if ($results{'wsrep_connected'} ne "ON")
{
  print "Critical: Node is not connected: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Critical'});
}

# check for data synchronisation status
if ($results{'wsrep_local_state_comment'} ne "Synced")
{
  print "Critical: Node is not synced: ".$results{'wsrep_cluster_status'}." - ".$results{'wsrep_local_state_comment'}."\n";
  exit($returnCodes{'Critical'});
}

# check for amount of nodes below the warning threshold
if ($results{'wsrep_cluster_size'} <= $amountOfNodesWarn)
{
  print "Warning: cluster_size: ".$results{'wsrep_cluster_size'}.", cluster_status: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Warning'});
}

# check for amount of nodes below the critical threshold
if ($results{'wsrep_cluster_size'} <= $amountOfNodesCrit)
{
  print "Critical: cluster_size: ".$results{'wsrep_cluster_size'}.", cluster_status: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Critical'});
}

# check the receiving queue..if this is larger than 0.5, the node is having load issues and is pauzing dataflows (not good)
if ($results{'wsrep_local_recv_queue_avg'} > 0.5)
{
  print "Warning: recv_queue_avg is higher than 0.5: ".$results{'wsrep_local_recv_queue_avg'}.", cluster_status: ".$results{'wsrep_cluster_status'}."\n";
  exit($returnCodes{'Warning'});
}

# we're all good!
print "OK cluster_size: ".$results{'wsrep_cluster_size'}.", cluster_status: ".$results{'wsrep_cluster_status'}.", local_state: ".$results{'wsrep_local_state_comment'}."\n";
exit($returnCodes{'OK'});
