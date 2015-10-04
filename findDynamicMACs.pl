#
#
# slotCardPortCapacity  -    This script discovers all dynamic MAC addresses and related it on a
#                            physical port. 
#                            Cisco and Huawei devices only. 
#
# Author            Emre Erkunt
#                   (emre.erkunt@superonline.net)
#
# History :
# -----------------------------------------------------------------------------------------------
# Version               Editor          Date            Description
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
# 0.0.1_AR              EErkunt         20141229        Initial ALPHA Release
# 0.0.2                 EErkunt         20150115        Asks for password if -p is not used
# 0.0.3                 EErkunt         20150223        Implented Huawei SNMP Stack
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#
# Needed Libraries
#
use threads;
use threads::shared;
use Getopt::Std;
use LWP::UserAgent;
use HTTP::Headers;
use LWP::Simple;
use Statistics::Lite qw(:all);
use LWP::UserAgent;
use Data::Dumper;
use Net::SNMP qw( :snmp DEBUG_ALL ENDOFMIBVIEW );
use DBI;
use DBD::mysql;
use Term::ReadPassword::Win32;

my $version     = "0.0.3";
my $arguments   = "u:p:i:o:hvt:a:nq";
my $MAXTHREADS	= 30;
getopts( $arguments, \%opt ) or usage();
$opt{n} = 1;		# Temporarily.
if ( $opt{q} ) {
	$opt{debug} = 1;		# Set this to 1 to enable debugging
}
$| = 1;
print "findDynamicMACs v".$version;
usage() if ( !$opt{i} or $opt{h} );
$opt{t} = 2 unless $opt{t};
if ($opt{v}) {
	$opt{v} = 0;
} else {
	$opt{v} = 1;
}

my @targets :shared;
my @ciNames;
unlink('upgradescpc.bat');

my $time = time();

$SIG{INT} = \&interrupt;
$SIG{TERM} = \&interrupt;

$ua = new LWP::UserAgent;
my $req = HTTP::Headers->new;

#
# Auto-update and Database Configuration Parameters
#
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

unless ($opt{n}) {
	#
	# New version checking for upgrade
	#
	$req = HTTP::Request->new( GET => $svnrepourl.$SVNScriptName );
	$req->authorization_basic( $SVNUsername, $SVNPassword );
	my $response = $ua->request($req);
	my $publicVersion;
	my $changelog = "";
	my $fetchChangelog = 0;
	my @responseLines = split(/\n/, $response->content);
	foreach $line (@responseLines) {
		if ( $line =~ /^# Needed Libraries/ ) { $fetchChangelog = 0; }
		if ( $line =~ /^my \$version     = "(.*)";/ ) {
			$publicVersion = $1;
		} elsif ( $line =~ /^# $version                 \w+\s+/g ) {
			$fetchChangelog = 1;
		} 
		if ( $fetchChangelog eq 1 ) { $changelog .= $line."\n"; }
	}
	if ( $version ne $publicVersion and length($publicVersion)) {		# SELF UPDATE INITIATION
		print "\nSelf Updating to v".$publicVersion.".";
		$req = HTTP::Request->new( GET => $svnrepourl.$SVNFinalEXEName.'.exe' );
		$req->authorization_basic( $SVNUsername, $SVNPassword );
		if($ua->request( $req, $SVNFinalEXEName.".tmp" )->is_success) {
			print "\n# DELTA CHANGELOG :\n";
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print "# Version               Editor          Date            Description\n";
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print $changelog;
			open(BATCH, "> upgrade".$SVNFinalEXEName.".bat");
			print BATCH "\@ECHO OFF\n";
			print BATCH "echo Upgrading started. Ignore process termination errors.\n";
			print BATCH "sleep 1\n";
			print BATCH "taskkill /F /IM ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "sleep 1\n";
			print BATCH "ren ".$SVNFinalEXEName.".exe ".$SVNFinalEXEName."_to_be_deleted  > NULL 2>&1\n";
			print BATCH "copy /Y ".$SVNFinalEXEName.".tmp ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName.".tmp > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName."_to_be_deleted > NULL 2>&1\n";
			print BATCH "del NULL\n";
			print BATCH "echo All done. Please run the ".$SVNFinalEXEName." command once again.\n\n";
			close(BATCH);
			print "Initiating upgrade..\n";
			sleep 1;
			exec('cmd /C upgrade'.$SVNFinalEXEName.'.bat');
			exit;
		} else {
			print "Can not retrieve file. Try again later. You can use -n to skip updating\n";
			exit;
		}
	} else {
		print " ( up-to-date )\n";
	}
} else {
	print " ( no version check )\n";
}

print "Verbose mode ON\n" if ($opt{v});
#
# Parsing CSV File
#
print "Reading input files. " if ($opt{v});
open(INPUT, $opt{i}) or die ("Can not read from file $opt{i}.");
while(<INPUT>) {
	chomp;
	if ( length($_) ) {
		if ( $_ =~ /(\d*\.\d*\.\d*\.\d*)/ ) {
			push(@targets, $1);
		}
	}
}
close(INPUT);
print "[ ".scalar @targets ." IPs parsed ]\n" if ($opt{v});

my @fileOutput;
my @completed :shared;

my $dbh = DBI->connect("dbi:mysql:$DBName;$DBHost", $DBUser, $DBPass) or die "FATAL ERROR : ".$DBI::errstr;
print "Database connection established.\n" if ( $opt{v} );
$dbh->disconnect();

#
# Main Loop
#
# Beware, dragons beneath here! Go away.
#
# Get the Password from STDIN 
#
print "Fetching information from ".scalar @targets." IPs.\n" if ($opt{v});
$opt{t} = $MAXTHREADS	if ($opt{t} > $MAXTHREADS);
print "Running on ".$opt{t}." threads.\n";

my @running = ();
my @Threads;
our @STDOUT :shared;


my $i = 0;

#
# Connect to DB on this stage to be sure that DB connection is ok.
#

our $swirlCount :shared = 1;
our $swirlTime  :shared = time();

while ( $i <= scalar @targets ) {
	@running = threads->list(threads::running);
	while ( scalar @running < $opt{t} ) {
		# print "New Thread on Item #$i\n";
		my $thread = threads->new( sub { &findDynamicMAC( $targets[$i] );});
		push (@Threads, $thread);
		@running = threads->list(threads::running);
		$i++;
		if ( $i >= scalar @targets ) {
			last;
		}
	}
	
	sleep 1;
	foreach my $thr (@Threads) {
		if ($thr->is_joinable()) {
			$thr->join;
		}
	}
	
	last unless ($targets[$i]);
}

@running = threads->list(threads::running);
print "Waiting for ".scalar @running." pending threads.\n"  if ($opt{v});
while (scalar @running > 0) {
	foreach my $thr (@Threads) {
		if ($thr->is_joinable()) {
			$thr->join;
		}
	}
	@running = threads->list(threads::running);
}	
print "\n";

print "\nAll done and saved on database.";
print "\n";
print "Process took ".(time()-$time)." seconds with $opt{t} threads.\n"   if($opt{v});

#
# Related Functions
#

sub findDynamicMAC ( $ ) {
	my $IP = shift;

	#
	# Initiate SNMP Object first
	my ($session, $error) = Net::SNMP->session(
                          -hostname      => $IP,
						  -version		 => $SNMPVersion,
                          -timeout       => 7,
                          -retries       => 2,
                          -community     => $SNMPCommunity,
                          -translate     => [-octetstring => 0],
                        );
	
	if ( !defined($session) ) {
		print "ERROR: SNMP connection failed to $IP. (ErrCode: ".$session->error.")\n";
		return 0;
	}
	#
	
	#
	# Identify Vendor and CI Name of Remote host
	my $vendorName = getSnmpOID( $session, '1.3.6.1.2.1.1.1.0' );
	my %oids;
	if ( $vendorName =~ /huawei/gi ) {
		$vendorName = "huawei";
		$oids{findVLANs} = "1.3.6.1.2.1.17.7.1.4.3.1.1";
		$oids{getDynMacs} = "1.3.6.1.2.1.17.4.3.1.2";
	} elsif ( $vendorName =~ /cisco/gi ) {
		$vendorName = "cisco";
		$oids{findVLANs}  = "1.3.6.1.4.1.9.9.46.1.3.1.1.4";
		$oids{getDynMacs} = "1.3.6.1.2.1.17.4.3.1.2";
	} elsif ( $vendorName =~ /alcatel-lucent/gi ) {
		$vendorName = "alcatel-lucent";
	} elsif ( $vendorName =~ /juniper/gi ) {
		$vendorName = "juniper";
	} elsif ( $vendorName =~ /ericsson/gi ) {
		$vendorName = "ericsson";
	} elsif ( $vendorName =~ /nec/gi ) {
		$vendorName = "nec";
	} elsif ( $vendorName =~ /paloalto/gi ) {
		$vendorName = "paloalto";
	}
	my $ciName = getSnmpOID( $session, '1.3.6.1.2.1.1.5.0');
	$STDOUT[$i] = "[".($i+1)."] [$IP] ($vendorName)\t$ciName";
	#

	my $dynamicMacCount = 0;
	my %ports;
	my @sth;
	print "VendorName : $vendorName\n" if ( $opt{debug} );
	
	if ( $vendorName eq "cisco" or $vendorName eq "huawei" ) {
		my %VLANIDs = getSnmpBulk( $session, $oids{findVLANs} );
		my @customerVLANs;
		$STDOUT[$i] .= " [".scalar(keys %VLANIDs)." VLANs]";
		my %s, %e;
		
		print "[$IP] Number of found VLANs : ".scalar(keys %VLANIDs)."\n" if ($opt{debug});
		my %customerVLANs;
		my %customerMACs;
		
		foreach my $key ( keys %VLANIDs ) {
			my @octets = split(/\./, $key);
			my $lastOctet = $octets[scalar(@octets)-1];
			if ( !in_array(\@ignoreList, $lastOctet) ) {
				my $newCommunity = $SNMPCommunity;
				if ( $vendorName eq "cisco" ) {
					$newCommunity = $SNMPCommunity."\@".$lastOctet;
					print "[$IP:$lastOctet] Changed SNMP community to $newCommunity\n" if ($opt{debug});
				} 
				($s{$lastOctet}, $e{$lastOctet}) = Net::SNMP->session(
							  -hostname      => $IP,
							  -version		 => $SNMPVersion,
							  -timeout       => 7,
							  -retries       => 2,
							  -community     => $newCommunity,
							  -translate     => [-octetstring => 1],
							);
		
				if ( !defined($s{$lastOctet}) ) {
					print "ERROR: SNMP connection failed to $IP ( with community ".$newCommunity." )\n";
					return;
				}
				
				
				#
				# Get available Dynamic MACs and Bridge Ports
				#
				%customerVLANs = getSnmpBulk( $s{$lastOctet}, $oids{getDynMacs} );
				print "[$IP:$lastOctet] Got ".scalar(keys %customerVLANs)." Dynamic MACs\n" if ($opt{debug});
				my $localMacCount = 0;
				foreach $cKey ( keys %customerVLANs ) {
					my $MAC;
					if ( $cKey =~ /\.(\d*)\.(\d*)\.(\d*)\.(\d*)\.(\d*)\.(\d*)$/ ) {
						$MAC = sprintf("%02x-%02x-%02x-%02x-%02x-%02x", $1, $2, $3, $4, $5, $6);
						push(@{$ports{$lastOctet}{$customerVLANs{$cKey}}}, $MAC);
						$localMacCount++;
						$dynamicMacCount++;
					}
					print "[$IP:$lastOctet] Found MAC : $MAC ($customerVLANs{$cKey})\n" if ( $opt{debug} );
				}
				print "[$IP:$lastOctet] Added ".scalar(keys(%ports))." Bridge Ports ($localMacCount MACs)\n" if ( $opt{debug} );
				# print "--- STEP 1 ---\n"; 
				# print Dumper(%ports);
				# print "--------------\n";
				#
				# Now we have a hash array called %ports including Bridge Ports -> Dynamic MACs relation
				#
				# Next step, let's find the interface name and continue.
				# 
				# First, let's find the ifIndex of related bridgePort
				#
				my %ifIndexes  = getSnmpBulk( $s{$lastOctet}, "1.3.6.1.2.1.17.1.4.1.2");
				my %interfaces = getSnmpBulk( $s{$lastOctet}, "1.3.6.1.2.1.31.1.1.1.1");
				
				foreach $indexKey ( keys %ifIndexes ) {
					my $bridgePort = $ifIndexes{$indexKey};
					my $bridgeID;
					if ( $indexKey =~ /\.(\d*)$/ ) { $bridgeID = $1; }
					if ( $bridgePort and $bridgeID ) {
						foreach $itfKey ( keys %interfaces ) {
							# print "Check ??? $itfKey <=?=> $bridgePort\n";
							if ( $itfKey =~ /.$bridgePort$/ and $ports{$lastOctet}{$bridgeID} ) {
								$ports{$lastOctet}{$interfaces{$itfKey}} = delete $ports{$lastOctet}{$bridgeID};
								$STDOUT[$i] .= " ($interfaces{$itfKey}:".scalar(@{$ports{$lastOctet}{$interfaces{$itfKey}}}).")" if ($opt{v});
								print "[$IP:$lastOctet] Converting ifIndex $bridgeID ( $bridgePort ) to $interfaces{$itfKey}\n" if ( $opt{debug} );
							}
						}
					}
				}
				# print "--- STEP 2 ---\n"; 
				# print Dumper(%ports);
				# print "--------------\n";
				
			} else {
				print "[$IP:$lastOctet] Skipping VLANID $lastOctet\n" if ($opt{debug});
			}				
		}
		$STDOUT[$i] .= " [".$dynamicMacCount." Dyn MACs] ";
	} elsif ( $vendorName eq "juniper" ) {
		print "[".($i+1)."] [$IP] ERROR: Juniper equipments have not been implemented yet.\n";
		return 0;
	} elsif ( $vendorName eq "alcatel-lucent" ) {
		print "[".($i+1)."] [$IP] ERROR: Alcatel-Lucent equipments have not been implemented yet.\n";
		return 0;
	} elsif ( $vendorName eq "nec" ) {
		print "[".($i+1)."] [$IP] ERROR: NEC equipments have not been implemented yet.\n";
		return 0;
	} elsif ( $vendorName eq "ericsson" ) {
		print "[".($i+1)."] [$IP] ERROR: Ericsson equipments have not been implemented yet.\n";
		return 0;
	} elsif ( $vendorName eq "paloalto" ) {
		print "[".($i+1)."] [$IP] ERROR: Paloalto equipments have not been implemented yet.\n";
		return 0;
	} else {
		print "[".($i+1)."] [$IP] ERROR: ".$session->error."\n";
		return 0;
	}
	
	#
	# Database interaction starts here
	my @dbh;
	$dbh[$i] = DBI->connect("dbi:mysql:$DBName;$DBHost", $DBUser, $DBPass) or die "FATAL ERROR : ".$DBI::errstr;
	my $sqlString;
	
	# 
	# Purge records older than 2 months
	
	foreach $vlanKey ( keys %ports ) {
		foreach $interfaceName ( keys %{$ports{$vlanKey}} ) {
			foreach $macAddress ( @{$ports{$vlanKey}{$interfaceName}} ) {
				$sqlString  = "INSERT INTO port_details 
									( ipAddress, ciName, vendorName, vlanID, macAddress, portName, insertTime )
								VALUES ( '".$IP."', 
										 '".$ciName."', 
										 '".$vendorName."', 
										 '".$vlanKey."', 
										 '".$macAddress."', 
										 '".$interfaceName."',
										 NOW())
								ON DUPLICATE KEY UPDATE
									ipAddress = '".$IP."', 
									ciName = '".$ciName."',
									vendorName = '".$vendorName."', 
									vlanID = '".$vlanKey."', 
									macAddress = '".$macAddress."', 
									portName = '".$interfaceName."',
									updateTime = NOW()";
									
				# print $sqlString."\n";
				$sth[$i] = $dbh[$i]->prepare($sqlString) or die $DBI::errstr; 
				$sth[$i]->execute() or die $DBI::errstr;
				$sth[$i]->finish();		
			}
		}
	}
	$dbh[$i]->disconnect();
	$STDOUT[$i] .= " [ DB Ok! ]";
	#
	$session->close();
	
	print $STDOUT[$i]."\n";
}

sub getSnmpOID ( $ $ ) {
	my $session = shift;
	my $OID = shift;

	print "[".$session->hostname()."] Querying $OID : " if ($opt{debug});
	my $result = $session->get_request(-varbindlist => [ $OID ],);
	
	if (!defined $result and $opt{debug}) {
		printf "ERROR: %s.\n", $session->error();
		return 0;
	}
 
	print $result->{$OID}."\n"  if ($opt{debug});
	return $result->{$OID};
}

sub getSnmpGroup ( $ $ ) {
	my $session = shift;
	my $OID = shift;
	my $checkPoint = shift;
	
	print "[".$session->hostname()."] Group Querying $OID ($checkPoint) : " if ($opt{debug});
	
	my @returns;
	
	my @args = ( -varbindlist =>  [$OID]);
	my $index;
	while ( defined $session->get_next_request(@args) ) {
        $_ = ( keys(%{ $session->var_bind_list }) )[0];
		my @n = split /\./, $_;
		$index = $n[($#n-$checkPoint)] if ( !$index );
		last if ( $index ne $n[($#n-$checkPoint)] );	
		
        # if (!oid_base_match($OID, $_)) { last; }
        printf("Group Result ($checkPoint) : %s => %s\n", $_, $session->var_bind_list->{$_}) if ($opt{debug});
		
		push( @returns, $session->var_bind_list->{$_} );
        @args = (-varbindlist => [$_]);
	}
	
	return @returns;
}

sub getSnmpBulk ( $ $ ) {
	my $s = shift;
	my $OID = shift;
	
	print "[".$s->hostname()."] Bulk Querying $OID\n" if ($opt{debug});

	my @varbindlist = ( $OID );
	my @args = ( 
		-varbindlist => \@varbindlist, 
		-maxrepetitions => 5,
		);
	
	my %results;
	
	outer: 
	while (defined($s->get_bulk_request( @args ))) {

            my @oids = oid_lex_sort(keys(%{$s->var_bind_list}));

            foreach (@oids) {
                    if (!oid_base_match($OID, $_)) { last outer; }
                    # printf("%s => %s\n", $_, $s->var_bind_list->{$_});
					$results{$_} = $s->var_bind_list->{$_};
                    # Make sure we have not hit the end of the MIB
                    if ($s->var_bind_list->{$_} eq 'endOfMibView') { last outer; } 
            }
        
            # Get the last OBJECT IDENTIFIER in the returned list
            @args = (-maxrepetitions => 5, -varbindlist => [ pop(@oids)  ]);
    }
	
	print "[".$s->hostname()."] ERROR: ".$s->error()."\n" if ($s->error());
	print "[".$s->hostname()."] Got ".scalar(keys(%results))." results.\n" if ($opt{debug});
	return %results;
}

sub swirl() {
	
	my $diff = 1;
	my $now = time();	
	
	if ( ( $now - $swirlTime ) gt 1 ) {
		if    ( $swirlCount%8 eq 0 ) 	{ print "\b|"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 1 ) 	{ print "\b/"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 2 ) 	{ print "\b-"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 3 ) 	{ print "\b\\"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 4 ) 	{ print "\b|"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 5 ) 	{ print "\b/"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 6 ) 	{ print "\b-"; $swirlCount++; }
		elsif ( $swirlCount%8 eq 7 ) 	{ print "\b\\"; $swirlCount++; }

		$swirlTime = $now;
	}
	return;
	
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub in_array {
     my ($arr,$search_for) = @_;
     my %items = map {$_ => 1} @$arr; 
     return (exists($items{$search_for}))?1:0;
}
 
sub usage {
		my $usageText = << 'EOF';
	
This script discovers all dynamic MAC addresses and related it on a physical port. 
Cisco and Huawei devices only. 

Author            Emre Erkunt
                  (emre.erkunt@superonline.net)

Usage : fdm [-i INPUT FILE] [-o OUTPUT FILE] [-v] [-u USERNAME] [-p PASSWORD] [-t THREAD COUNT] [-n]

Example INPUT FILE format is ;
------------------------------
172.28.191.196
172.28.191.194
172.28.191.193
------------------------------

 Parameter Descriptions :
 -i [INPUT FILE]        Input file that includes IP addresses
 -o [OUTPUT FILE]       Output file about results
 -n                     Skip self-updating
 -t [THREAD COUNT]      Number of threads that should run in parallel      ( Default 2 threads )
 -v                     Disable verbose                                    ( Default ON )

EOF
		print $usageText;
		exit;
}   # usage()

sub interrupt {
    print STDERR "Stopping! Be patient!\n";
	undef @targets;
	exit 0;
}
