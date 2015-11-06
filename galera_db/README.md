This script connects to a MySQL of MariaDB database servers and gets information about the Galera Cluster (http://galeracluster.com/) to use that information to determine the health of the cluster and then return the health status in a format that nagios understands.

This script needs a database user, preferbly one with only USAGE rights. Here's an example:
    GRANT USAGE ON *.* TO 'myuser'@'myhost' IDENTIFIED BY 'mypassword';

EXAMPLE on how to use it in nagios:

define service {
        host_name db1.local
        service_description     MySQL - Check Galera Cluster Status
        check_command           check_galera_status.pl!-h $HOSTADDRESS$ -u myuser -p mypassword --nodes-warn=2 --nodes-crit=1
        normal_check_interval   5
        retry_check_interval    1
        check_period            24x7
        max_check_attempts      3
        flap_detection_enabled  1
        notifications_enabled   1
        notification_period     24x7
        notification_interval   60
        notification_options    c,f,r,u,w
        contact_groups  hostgroup4_servicegroup49
        notes   Database - Galera:Checks a Galera Cluster for functionality
        use     service-global
}

Martijn Smit <martijn@lostdomain.org>

06-11-2015: First commit