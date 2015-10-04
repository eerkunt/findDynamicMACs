# findDynamicMACs

This script tries to discover Active MACs on given IPs and records them into MySQL.

# How to run ?

You need to change few lines inside the script ;
```perl
my $svnrepourl  = ""; 			# Your private SVN Repository (should be served via HTTP). Do not forget the last /
my $SVNUsername = "";			# Your SVN Username
my $SVNPassword = "";			# Your SVN Password
my $SVNScriptName = "findDynamicMACs.pl";
my $SVNFinalEXEName = "fdm";
my $DBHost = "";			# Your MySQL Hostname/IP
my $DBPort = "3306";			# Your MySQL Port, Default : 3306
my $DBName = "";			# Your MySQL Database/Schema Name	
my $DBUser = "";			# Your MySQL Database Username
my $DBPass = "";			# Your MySQL Database Password
my $DBTable = "port_details";		# Your MySQL Table Name given Database/Schema
my $SNMPVersion = "2";
my $SNMPCommunity = 'public';		# Your SNMP Community, Default : public
our @ignoreList = ( 1, 4, 996, 1002, 1003, 1004, 1005, 103, 697, 695, 696, 111 );	# Do not track these VLANs
```

I will also add SQL schema into repository later.
