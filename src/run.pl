#!perl
$\=$/;

#
# Le client du D-MON : une boucle principale tourne toutes les N(180) secondes
# pour envoyer une commande "ALIVE" au serveur.
#

use strict;

use AnyEvent;
use AnyEvent::WebSocket::Client;

use AnyEvent::Open3::Simple;

use JSON;
use Config::JSON;
use REST::Client;

use Centrifugo::Client;

my $DEFAULT_TIMEOUT=15;
my $EXEC_UPDATE_INTERVAL=3;
my $ALIVE_INTERVAL=180;
our $CONFIG_FILE=$ARGV[0] || ( $^O=~/Win/i ? "C:/Windows/Temp/config.json" : "/tmp/config.json" );

our $SERVER_BASE_API=$ENV{"DMON_API"};
our $CENTRIFUGO_WS=$ENV{"CENT_WS"};

die "DMON_API environment variable must be set" unless $SERVER_BASE_API;
die "CENT_WS environment variable must be set" unless $CENTRIFUGO_WS;


my $CENTREON_PLUGINS_DIR=$ENV{"CENTREON_PLUGIN_ROOT"} || '/var/lib/centreon-plugins';
my $CENTREON_PLUGINS='centreon_plugins.pl';

my @ALT_CENTREON_ROOT = ( "../../centreon-plugins/", "../centreon-plugins/", "./centreon-plugins/");

while (@ALT_CENTREON_ROOT && !-f "$CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS") {
	$CENTREON_PLUGINS_DIR = shift @ALT_CENTREON_ROOT;
}

my $API_KEY = "key-123";

my $USER_ID = "First_User_12345";
my $TIMESTAMP = time();
my $TOKEN;

our $HOST_ID;

our $mainEventLoop;
our $centrifugoClientHandle;

our %execs;
our %execHandles;

# Initialize the monitor
init();

# Ask for a client token
$TOKEN = askForToken($USER_ID,$TIMESTAMP);

# Connects to Centrifugo
connectToCentrifugo();

# Start the event loop
AnyEvent->condvar->recv;
exit;



###########################################################
#   makeEvent* subs are launching tasks in the event loop

sub connectToCentrifugo {
	$centrifugoClientHandle = Centrifugo::Client->new("$CENTRIFUGO_WS/connection/websocket",
		debug => 'true',
		ws_params => {
			ssl_no_verify => 'true',
			timeout => 600
	});

	$centrifugoClientHandle->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN
	) -> on('connect', sub{
		my ($infoRef)=@_;
		print "Connected to Centrifugo version ".$infoRef->{version};
		
		# When connected, client_id() is define, so we can subscribe to our private channel
		$centrifugoClientHandle->subscribe( channel => '&'.$centrifugoClientHandle->client_id() );
				
		# For now : loop and ping the server every 10 s
		makeServerEventLoop();
		
	})-> on('message', sub{
		my ($infoRef)=@_;
		processServerCommand($infoRef->{data});
	})-> on('disconnect', sub {
		undef $centrifugoClientHandle;
	});
}

# Creates an event to ping the server every X minutes with an "alive" event
sub oldmakeAliveEventServerEvery { # J4ai sauvé cette fonction avant sa modification plus loin
	my $interval = shift;
	$mainEventLoop = AnyEvent->timer(
		after => 0,
		interval => $interval,
		cb => sub {
			my $response = sendMessageToServer( 'ALIVE', { 'PERIOD', $ALIVE_INTERVAL } );
			processServerJsonCommand($response) if $response;
		}
	);
}

# Creates an event to ping the server every X minutes with an "alive" event
sub makeServerEventLoop{
	my $config = openOrCreateConfigFile();
	my $instancesHashRef = $config->get("instances");
	my @instanceIDs = keys %$instancesHashRef;
	my $instanceCheckCount = 1+@instanceIDs;
	my $interval = int( $ALIVE_INTERVAL / $instanceCheckCount );
	my $counter = 0;
	$mainEventLoop = AnyEvent->timer(
		after => 0,
		interval => $interval,
		cb => sub {
			if ($counter==0) {
				my $response = sendMessageToServer( 'ALIVE', { 'PERIOD', $interval } );
				processServerJsonCommand($response) if $response;
			} else {
				my $instanceId = $instanceIDs[ $counter-1 ];
				my $cmdline = $config->get("instances/$instanceId");
				processInstance($instanceId, $cmdline);
			}
			$counter++; $counter %= $instanceCheckCount;
		}
	);
}

sub askForToken {
	my ($user,$timestamp)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	
	my $POST = qq!user=$user&timestamp=$timestamp!;
	$client->POST("/token.php", $POST, { 'Content-type' => 'application/x-www-form-urlencoded'});
	print "POST > $POST";
	print "     < (".$client->responseCode().')';
	my $token =my $tokenOutput=$client->responseContent();
	$tokenOutput=~s/^/     < /mg;
	print $tokenOutput;
	if ($client->responseCode() eq 200) {
		return($token);
	}
	print "ERROR < No websocket token";
}

###########################################################

sub init {
	my $config = openOrCreateConfigFile();	
	$HOST_ID = $config->get('host_id');
	unless ($HOST_ID) {
		$HOST_ID = `hostname`; # Works on Linux AND Win32
		chomp $HOST_ID;
		$config->set('host_id',$HOST_ID);
	}
}

sub openOrCreateConfigFile {
	if (-f $CONFIG_FILE) {
		return Config::JSON->new($CONFIG_FILE);
	} else {
		print STDERR "Config file $CONFIG_FILE not found : Creating...";
		return  Config::JSON->create($CONFIG_FILE);
	}
}

# Sends a notification to the server. The parameter is a HashRef (api-key, host-id and client-id parameters will be added here)
sub sendMessageToServer {
	my ($type, $dataHRef)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	my $CLIENT_ID = $centrifugoClientHandle ? $centrifugoClientHandle->client_id() : undef;
	$dataHRef->{ 't' }=$type;
	$dataHRef->{ 'api-key' }=$API_KEY;
	$dataHRef->{ 'client-id' }=$CLIENT_ID;
	$dataHRef->{ 'host-id' }=$HOST_ID;
	my $POST = encode_json $dataHRef;
	$client->POST("/msg.php", $POST, { 'Content-type' => 'application/json'});
	print "$type > $POST";
	print "    < (".$client->responseCode().')';
	my $response=my $resOutput=$client->responseContent();
	if ($response) {
		$resOutput=~s/^/    < /mg;
		print $resOutput;
	}
	return $response;
}

# This takes a command expressed in JSON, sends a ACK to the server, then executes the command and
# sends the result back to the server
# The struct for a command is :
# { "t":"CMD", "id":"CmdID", "cmd":"...", "args":{...} }
# The struct for a ACK/Notification is :
# { "t":"ACK", "id":"CmdID" } or if the JSON is invalid : { "t":"ACK", "id":null, "message":"..." }
# the struct for a result is :
# { "t":"RESULT", "id":"CmdID","status":"0-4", ["message":"...",] ["retcode":"...",] ["STDOUT":"...",] ["STDERR":"..."] }  
#    (status code values are Nagios-compliant : 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN, 4=PENDING)
#     a value of 4(PENDING) means that the command is NOT finished, and that other messages will follow (partial result)
sub processServerJsonCommand {
	my ($jsonCmd) = shift;
	my $command = 
		eval {
			decode_json $jsonCmd;
		} or do {
			my $error = $@;
			sendMessageToServer( 'ACK', { id => undef, message => $error });
			return;
		};
		
	processServerCommand($command);
}

sub processServerCommand {
	my ($command) = shift;
	# Envoi d'un ACK
	my $cmdId = $command->{id};
	sendMessageToServer( 'ACK', { id => $cmdId });

	# Traitement de la commande
	my $cmd = uc $command->{cmd};

	if ('CONNECT' eq $cmd) {
		connectToCentrifugo();	
	}
	elsif ('DISCONNECT' eq $cmd) {
		$centrifugoClientHandle->disconnect() if $centrifugoClientHandle;
	}
	else {
		# List of known commands :   RUN
		if ('RUN' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			if ($cmdline =~ s/^CHECK\b *//i) {
				processCheckCommand($cmdId, $cmdline);
			} else {
				processRunCommand($cmdId, $cmdline);
			}
		}
		elsif ('REGISTER' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			registerCheckCommand($cmdId, $cmdline);
		}
		elsif ('UNREGISTER' eq $cmd) {
			my $serviceId = $command->{args}->{serviceId};
			unregisterCheckCommand($cmdId, $serviceId);
		}
		elsif ('HELP' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			processHelpOnCheckCommand($cmdId, $cmdline);
		}
		else {
			print "### ERROR : Unknown command : $cmd : ". 
				join';',map {"'$_'=>'".$command->{args}->{$_}."'"} keys %{$command->{args}};
		}
	}
}

# Execute a system command.
# Output 4 values :
# status (0=OK, 2=Error while running command)
# retCode : return code of the command
# stdout, stderr
sub executeCommandArchive {
	my ($cmdline)=@_;
	use IPC::Open3;
	my $status=0; # OK
	my $retval=0;
	my $stdout="";
	my $stderr="";
	my $pid = eval {
		open3(\*WRITER, \*READER, \*ERROR, $cmdline);
	} or do {
		$status=2; # CRITICAL
		$stderr=$@;
		$stderr=~s/^open3: +//;
		0;
	}; 
	if ($pid) {
		my $line;
		$stdout.=$line while $line=<READER>;
		$stderr.=$line while $line=<ERROR>;
		waitpid( $pid, 0 ) or warn "$!";
		$retval = $?;
	}
	return ($status, $retval, $stdout, $stderr);
}

# Forks the execution of a system command. The details of the execution are stored in 
# $execs{ $cmdId } = { handle=>..., PID=>... , shortCmd=>..., cmdline=>..., stdout=>[], stderr=>[] }
# and
# $execHandles { $cmdId } = { exec=>..., update=>...}
# (these handle keeps the fork and the update timer alive)
# Input :
#    cmdId : the ID of the Centrifugo request
#    $shortCmd : the user-friendly commandline (may be shorter that the full one)
#    $cmdLine : the command line to execute
# Output 4 values :
# status (0=OK, 2=Error while running command)
# retCode : return code of the command
# stdout, stderr
sub executeCommand {
	my ($cmdId, $shortCmd, $cmdline)=@_;
	
	my $done = AnyEvent->condvar;

	my $ipc = AnyEvent::Open3::Simple->new(
		on_start => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			print STDERR "EXEC[$cmdId] child PID: ", $proc->pid, ", program: ",$program;
			$execs{$cmdId} = {
				id => $cmdId,
				PID => $proc->pid,
				cmdline => $shortCmd,
				stdout => [],
				stderr => [],
				terminated => 0,
				timeoutAt => time()+$DEFAULT_TIMEOUT
			};
		},
		on_stdout => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stdout}}, $line;
			print STDERR 'out: ', $line;
		},
		on_stderr => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stderr}}, $line;
			print STDERR 'err: ', $line;
		},
		on_exit   => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $exit_value = shift; # integer
			my $signal = shift;     # integer
			$execs{$cmdId}->{retval} = $exit_value;
			$execs{$cmdId}->{signal} = $signal;
			terminateExecutionAndSendResults($cmdId);
		},
		on_error => sub {
			my $error = shift;      # the exception thrown by IPC::Open3::open3
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			warn "error: $error";
			$execs{$cmdId}->{status} = 2; # CRITICAL
			$execs{$cmdId}->{error} = $error;
			$execs{$cmdId}->{errorInfos} = \@args;
			terminateExecutionAndSendResults($cmdId);
		},
	);

	# Send result updates on a regular basis
	my $updates = AnyEvent->timer(
		after => $EXEC_UPDATE_INTERVAL,
		interval => $EXEC_UPDATE_INTERVAL,
		cb => sub {
			# Check Timeout
			if (time()>$execs{$cmdId}->{timeoutAt}) {
				terminateExecutionAndSendResults($cmdId) ;
			} else {
				sendResultForExecution($cmdId);
			}
		}
	);
	
	$execHandles{$cmdId} = { handle=> $ipc, update=> $updates };
	$ipc->run($cmdline);
}

sub terminateExecutionAndSendResults{
	my($cmdId)=@_;
	$execs{$cmdId}->{terminated} = 1;
	undef $execHandles{$cmdId}->{handle};
	undef $execHandles{$cmdId}->{update};
	delete $execHandles{$cmdId};
	sendResultForExecution($cmdId);
}

sub sendResultForExecution{
	my($cmdId)=@_;
	sendMessageToServer('RESULT', $execs{$cmdId});
	delete $execs{$cmdId} if $execs{$cmdId}->{terminated};
}

sub sendResultErrorMessage{
	my($cmdId,$message)=@_;
	sendMessageToServer('RESULT', {
		id => $cmdId,
		stdout => [],
		stderr => [ $message ]
	});
}

###################### COMMANDS #######################

sub processRunCommand {
	my ($cmdId, $cmdline)=@_;
	print "RUN[$cmdId]:$cmdline";
	executeCommand($cmdId, $cmdline, $cmdline);
}

sub processCheckCommand {
	my ($cmdId, $cmdline)=@_;
	print "CHECK[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand($cmdId, $cmdline, $fullCmdline);
}

sub processInstance {
	my ($iId, $cmdline)=@_;
	print "INSTANCE[$iId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand($iId, $cmdline, $fullCmdline);
}

sub processHelpOnCheckCommand {
	my ($cmdId, $cmdline)=@_;
	unless ($cmdline =~ s/^CHECK\b *//i) {
		sendResultErrorMessage($cmdId, "Help only works on CHECK commands");
		return;
	}
	print "HELP[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS --help $cmdline";
	executeCommand($cmdId, $cmdline, $fullCmdline);
}

sub registerCheckCommand {
	my ($cmdId, $cmdline)=@_;
	print "REGISTER[$cmdId]:$cmdline";
	my $instanceId = $cmdline; $instanceId=~s/\W+/_/g;
	my $config = openOrCreateConfigFile();
	my %instances = $config->addToHash('instances',$instanceId,$cmdline);
	# Envoi du premier résultat (TODO : change to send instanceId)
	processInstance($instanceId,$cmdline);
	makeServerEventLoop();
}

sub unregisterCheckCommand {
	my ($cmdId, $instanceId)=@_;
	print "UNREGISTER[$cmdId]:$instanceId";
	my $config = openOrCreateConfigFile();
	$config->deleteFromHash('instances',$instanceId);
	makeServerEventLoop();
}

