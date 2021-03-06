#!/usr/bin/perl
$\=$/;

my $VERSION = "0.2.2";

#
# Le client du D-MON : une boucle principale tourne toutes les N(180) secondes
# pour envoyer une commande "ALIVE" au serveur.
#
# La syntaxe pour lancer le client est
#
# perl ./run.pl --daemon <API_KEY> [ <config_file_path> ]
#


use strict;

# Daemon mode. Launch with "perl run.pl --daemon [config.file]". This will launch another perl process with the real client
# Whenever the client receives a !reload command, it exits and is automatically re-run.
if ($ARGV[0]=~/--daemon/) {
	print "Running daemon";
	my @incs = map "-I $_", @INC;
	die "Syntax is $0 --daemon <API_KEY> [ <config_file> ]" unless checkApiKey($ARGV[1]);
	while(1) {
		qx!perl @incs $0 $ARGV[1] $ARGV[2]!; # TODO : STDOUT if swallowed here.
		print "Reloading daemon";
	}
}

use AnyEvent;
use AnyEvent::WebSocket::Client;

use AnyEvent::Open3::Simple;

use JSON;
use Config::JSON;
use REST::Client;

use Centrifugo::Client;

# Timeout des executions en arrière plan (fork)
my $EXECUTION_TIMEOUT=15;
# Intervalle d'envoi des mises à jour des sorties des fork
my $EXEC_UPDATE_INTERVAL=3;
# Intervalle d'envoi d'un message ALIVE au serveur
my $ALIVE_INTERVAL=60 * 1; 
# Le delai après lequel une premiere sortie de fork est envoyée
my $FIRST_RESULT_DELAY=0.8;


die "Syntax is $0 <API_KEY> [ <config_file> ]" unless checkApiKey($ARGV[0]);
my $API_KEY = $ARGV[0];
our $CONFIG_FILE=$ARGV[1] || "./config.json";

our $SERVER_BASE_API=$ENV{"DMON_API"} || 'https://dmon.crocoware.com';
our $CENTRIFUGO_WS=$ENV{"CENT_WS"} || 'wss://centrifugo.crocoware.com';
my $CENTREON_PLUGINS_DIR=$ENV{"CENTREON_PLUGIN_ROOT"} || './plugins/centreon-plugins';

# ASIS : The centreon plugin is the first (and only) one that is usable for now.
# TODO : Should be evolutive and accept other plugin repositories to extend the possibilitites
my $CENTREON_PLUGINS='centreon_plugins.pl';

our $TOKEN_API_URL = '/api/token.php';
our $MSG_API_URL = '/api/send-msg.php';
our $CENT_AUTH_URL = "$SERVER_BASE_API/auth.php";

my $USER_ID; # A random string : will be create in init() and stored
my $TIMESTAMP = time();
my $INFO = { class => 'host' };
my $TOKEN;

our $HOST_ID;

our $mainEventLoop;
our $centrifugoClientHandle;

our %execs;
our %execHandles;

# Initialize the monitor
init();

# Ask for a client token
my $AUTH = askForAuth($USER_ID,$API_KEY,$TIMESTAMP);
my $TOKEN = $AUTH->{token};
my $GROUPS = $AUTH->{groups};

# Connects to Centrifugo
connectToCentrifugo( $GROUPS );

# Start the event loop
AnyEvent->condvar->recv;
exit;

sub checkApiKey {
	my $key = shift;
	return $key=~/^\w{8}-(\w{4}-){3}\w{12}$/;
}

sub init {
	my $config = openOrCreateConfigFile();
	# If the host_ID is not yet known, then fix it
	getOrSetHostname( $config );
	# creates a new unique Centrifugo client ID each run
	createClientId( $config );
	# Check if the plugin repositories are there.
	checkOrCreateRepositories();
}

sub getOrSetHostname {
	my ($config)=@_;
	$HOST_ID = $config->get('host_id');
	unless ($HOST_ID) {
		$HOST_ID = qx!hostname!; # Works on Linux AND Win32
		chomp $HOST_ID; $HOST_ID =~ s/\W/-/g;
		# If the client is launched from docker with --volume /etc/hostname:/etc/docker-hostname
		# then the REAL hostname of the client can be used
		if (-f '/etc/docker-hostname') {
			my $dockerHostName = qx!cat /etc/docker-hostname!; # linux container
			chomp $dockerHostName;
			$HOST_ID .= '@'.$dockerHostName;
		}

		$config->set('host_id',$HOST_ID);
	}
}

sub createClientId {
	my ($config)=@_;
	$USER_ID = $config->get('message_client_id');
	unless($USER_ID) {
		use Data::UUID;
		$USER_ID = lc Data::UUID->new->create_str();
		$config->set('message_client_id',$USER_ID);
	}
}

sub checkOrCreateRepositories {
	# TODO : for now, only check for centreon-plugins
	unless (-e $CENTREON_PLUGINS_DIR) {
		# TODO : The url is in plugins/repositories.json and should be used
		print "Repository Centreon missing :";
		my $cmd = qq!git clone https://github.com/centreon/centreon-plugins $CENTREON_PLUGINS_DIR!;
		print "> $cmd";
		my $output = qx!$cmd!;
		print $output;
	}
}

###########################################################
#   makeEvent* subs are launching tasks in the event loop

sub connectToCentrifugo {
	my ($groups) = @_;
	
	$centrifugoClientHandle = Centrifugo::Client->new("$CENTRIFUGO_WS/connection/websocket",
		debug => 'true',
		debug_ws => 'false',
		authEndpoint => $CENT_AUTH_URL,
		max_alive_period => 49,
		refresh_period => 10,
		retry => 0.5 ,
	#	ws_params => {
	#		ssl_no_verify => 'true',
	#		timeout => 600
	#}
	);

	$centrifugoClientHandle->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN,
		info => encode_json $INFO
	)-> on('connect', sub {
		# Sends an ALIVE message telling we're there
		sendAliveMessage( {  } );
		# Subscribe to listening private channel
		subscribeMyChannels( $centrifugoClientHandle, $groups );
	})-> on('message', sub{
		my ($infoRef)=@_;
		# Only read data written into own channel		
		processServerCommand($infoRef->{data}) if $infoRef->{channel}=~/&/;
	})-> on('disconnect', sub {
		print "DISCONNECT !!";
		undef $centrifugoClientHandle;
	});

	# For now : loop and ping the server every N seconds
	makeServerEventLoop();
}

sub subscribeMyChannels {
	my ($centrifugoClientHandle, $groups) = @_;
	$centrifugoClientHandle->subscribe( channel => '&' );
	foreach my $group (@$groups) {
		# Also subscribe to the private broadcast group channels
		$centrifugoClientHandle->subscribe( channel => '$broadcast_'.$group ) if $group;
	}
	$centrifugoClientHandle->on ('subscribe', sub{
		my( $dataRef ) = @_;
		if ($dataRef->{'channel'}=~/^&/) {
			# Send a message for the console
			sendResultErrorMessage('_init_', getVersion());
		}
	});
}

# Creates an event to ping the server every X minutes with an "alive" event
sub makeServerEventLoop{
	my $config = openOrCreateConfigFile();
	my $instancesHashRef = $config->get("instances");
	my @instanceIDs = keys %$instancesHashRef;
	my $instanceCheckCount = 1+@instanceIDs;
	my $interval = 1+int( $ALIVE_INTERVAL / $instanceCheckCount ); # TODO : refaire ce calcul
	my $counter = 0;
	$mainEventLoop = AnyEvent->timer(
		after => 0,
		interval => $interval,
		cb => sub {
			if ($counter==0) {
				sendAliveMessage( { 'PERIOD', $interval } );
			} else {
				my $instanceId = $instanceIDs[ $counter-1 ];
				my $cmdline = $config->get("instances/$instanceId");
				processInstance($instanceId, $cmdline);
			}
			$counter++; $counter %= $instanceCheckCount;
		}
	);
}

sub sendAliveMessage {
	my ($data) = @_;
	my $response = sendMessageToServer( 'ALIVE', $data );
	processServerJsonCommand($response) if $response;
}

sub askForAuth {
	my ($user,$apiKey,$timestamp)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	my $data = {};
	$data->{user} = $user;
	$data->{api_key} = $apiKey;
	$data->{timestamp} = $timestamp;
	$data->{info} = $INFO;
	my $POST = encode_json $data;
	$client->POST($TOKEN_API_URL, $POST, { 'Content-type' => 'application/json'});
	print "REQ_TOKEN > $POST";
	print "          < (".$client->responseCode().')';
	my $result =$client->responseContent();
	print "     < $result";
	if ($client->responseCode() eq 200) {
		return(decode_json $result);
	}
	print "ERROR < No websocket token (HTTP:".$client->responseCode().')';
}

###########################################################

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
	$client->POST($MSG_API_URL, $POST, { 'Content-type' => 'application/json'});
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
			decode_json $jsonCmd; # TODO : Error here (not JSON) when centrifugo shut down
		} or do {
			my $error = $@;
			sendMessageToServer( 'ACK', { id => undef, message => $error });
			return;
		};
		
	processServerCommand($command);
}

sub getDefaultCommandEnv() {
	my %ENV;
	$ENV{ TIMEOUT } = $EXECUTION_TIMEOUT;
	return %ENV;
}

sub processServerCommand {
	my ($command) = shift;
	# Envoi d'un ACK
	my $cmdId = $command->{cmdId};
	sendMessageToServer( 'ACK', { cmdId => $cmdId });

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
			
			# Traitement des variables d'environnements ("TIMEOUT=600 ...")
			my %ENV=getDefaultCommandEnv();
			while ($cmdline=~s/^\s*([\w\-]+)=(\S+)\s*//) {
				$ENV{ $1 } = $2;
				print "[$cmdId] ENV{$1}=$2";
			}

			if ($cmdline =~ /^!/) {
				# Special commands starts with !
				if ($cmdline =~ s/^!HELP\b *//i) {
					sendResultErrorMessage($cmdId, getHelp());
				} elsif ($cmdline =~ s/^!CHECK\b *//i) {
					processCheckCommand($cmdId, $cmdline, %ENV);
				} elsif ($cmdline =~ s/^!RELOAD\b *//i) {
					exit(0);
				} elsif ($cmdline =~ s/^!UPDATE\b *//i) {
					processRunCommand($cmdId, 'git pull', %ENV);
				} elsif ($cmdline =~ s/^!VERSION\b *//i) {
					sendResultErrorMessage($cmdId, getVersion());
				} else {
					$cmdline=~s/ .*//;
					sendResultErrorMessage($cmdId, "Unknown command '$cmdline'");
				}
			} else {
				processRunCommand($cmdId, $cmdline, %ENV);
			}
		}
		elsif ('KILL' eq $cmd) {
			my $cmdId = $command->{args}->{cmdId};
			# Kills the pending process
			print "### KILLS cmdId=$cmdId";
			killExecution($cmdId);
		}
		elsif ('REGISTER' eq $cmd) {
			my $instanceId = $command->{args}->{id};
			my $cmdline = $command->{args}->{cmdline};
			registerCheckCommand($cmdId, $instanceId, $cmdline);
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
			print "### ERROR : Unknown command : $cmd";
		}
	}
}

# Forks the execution of a system command. The details of the execution are stored in 
# $execs{ $cmdId } = { handle=>..., PID=>... , shortCmd=>..., cmdline=>..., stdout=>[], stderr=>[] }
# and
# $execHandles { $cmdId } = { exec=>..., update=>...}
# (these handle keeps the fork and the update timer alive)
# Input :
#    $type : the type-name of the result that will be sent back to server (RESULT or SERVICE)
#    $cmdId : the ID of the Centrifugo request
#    $shortCmd : the user-friendly commandline (may be shorter that the full one)
#    $cmdLine : the command line to execute
# Output 4 values :
# status (0=OK, 2=Error while running command)
# retCode : return code of the command
# stdout, stderr
sub executeCommand {
	my ($type, $serviceId, $cmdId, $shortCmd, $cmdline, %ENV)=@_;

	my $ipc = AnyEvent::Open3::Simple->new(
		on_start => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			print STDERR "EXEC[$cmdId] child PID: ", $proc->pid, ", program: ",$program;
			$execs{$cmdId} = {
				t => $type,
				id => $serviceId,
				cmdId => $cmdId,
				PID => $proc->pid,
				cmdline => $shortCmd,
				stdout => [],
				stderr => [],
				status => 0,
				terminated => 0,
				timeoutAt => time()+$ENV{TIMEOUT}
			};
		},
		on_stdout => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stdout}}, $line;
			print STDERR "STDOUT[$cmdId]: $line";
		},
		on_stderr => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stderr}}, $line;
			print STDERR "STDERR[$cmdId]: $line";
		},
		on_exit   => sub { # Called when the processes completes, either because it called exit, or if it was killed by a signal.
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $exit_value = shift; # integer
			my $signal = shift;     # integer
			$execs{$cmdId}->{exit_value} = $exit_value;
			$execs{$cmdId}->{signal} = $signal;
			print "EXIT[$cmdId]";
			terminateExecutionAndSendResults($cmdId);
		},
		on_error => sub { # Called when there is an execution error, for example, if you ask to run a program that does not exist. No process is passed in because the process failed to create. 
			my $error = shift;      # the exception thrown by IPC::Open3::open3
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			warn "ERROR[$cmdId]: $error";
			unshift @args, $error;
			$execs{$cmdId}->{status} = 2; # CRITICAL
			$execs{$cmdId}->{t} = $type;
			$execs{$cmdId}->{id} = $serviceId;
			$execs{$cmdId}->{cmdId} = $cmdId;
			$execs{$cmdId}->{stdout} = [];
			$execs{$cmdId}->{stderr} = \@args;
			terminateExecutionAndSendResults($cmdId);
		},
		on_signal => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $signal = shift;     # integer
			print "SIGNAL[$cmdId]: $proc / signal=$signal";
		},
		on_fail => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $exit_value = shift; # integer
			print "FAIL[$cmdId]: $proc / exit_value=$exit_value";
		},
	);

	# Send result updates on a regular basis
	my $updates = AnyEvent->timer(
		after => $FIRST_RESULT_DELAY,
		interval => $EXEC_UPDATE_INTERVAL,
		cb => sub {
			# Check Timeout
			if (time()>$execs{$cmdId}->{timeoutAt}) {
				print "TIMEOUT[$cmdId] ENV{TIMEOUT}=".$ENV{TIMEOUT};
				killExecution($cmdId) ;
				undef $execHandles{$cmdId}->{update};
			} else {
				if ($type ne 'SERVICE') { # Services don't update their result before completion or timeout
					sendResultForExecution($cmdId);
				}
			}
		}
	);
	
	$execHandles{$cmdId} = { handle=> $ipc, update=> $updates };
	$ipc->run($cmdline);
}

sub killExecution{
	my($cmdId)=@_;
	unless($execs{$cmdId}->{terminated}) {
		$execs{$cmdId}->{killed}=1;
		my $pid = $execs{$cmdId}->{PID};
		if ($pid=~/^\d+$/) { # Avoid "Can't kill a non-numeric process ID"
			print "KILL[$cmdId] PID=$pid";
			kill 'KILL', $pid;
		}
	}
}

sub terminateExecutionAndSendResults{
	my($cmdId)=@_;
	unless($execs{$cmdId}->{terminated}) {
		$execs{$cmdId}->{terminated} = 1;
		undef $execHandles{$cmdId}->{handle};
		undef $execHandles{$cmdId}->{update};
		delete $execHandles{$cmdId};
		sendResultForExecution($cmdId);
	}
}

sub sendResultForExecution{
	my($cmdId)=@_;
	sendMessageToServer($execs{$cmdId}->{t}, $execs{$cmdId});
	delete $execs{$cmdId} if $execs{$cmdId}->{terminated};
}

sub sendResultMessage{
	my($cmdId,$message)=@_;
	sendMessageToServer('RESULT', {
		cmdId => $cmdId,
		terminated => 1,
		stdout => [ $message ],
		stderr => []
	});
}

sub sendResultErrorMessage{
	my($cmdId,$message)=@_;
	sendMessageToServer('RESULT', {
		cmdId => $cmdId,
		terminated => 1,
		stdout => [],
		stderr => [ $message ]
	});
}

###################### COMMANDS #######################

sub processRunCommand {
	my ($cmdId, $cmdline, %ENV)=@_;
	print "RUN[$cmdId]:$cmdline";
	executeCommand('RESULT', undef, $cmdId, $cmdline, $cmdline, %ENV);
}

sub processCheckCommand {
	my ($cmdId, $cmdline, %ENV)=@_;
	print "CHECK[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand('RESULT', undef, $cmdId, $cmdline, $fullCmdline, %ENV);
}

sub processInstance {
	my ($iId, $cmdline)=@_;
	print "INSTANCE[$iId]:$cmdline";
	$cmdline=~s/^!//;
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand('SERVICE', $iId, undef, "!$cmdline", $fullCmdline);
}

sub processHelpOnCheckCommand {
	my ($cmdId, $cmdline)=@_;
	unless ($cmdline =~ s/^CHECK\b *//i) {
		sendResultErrorMessage($cmdId, "Help only works on CHECK commands");
		return;
	}
	print "HELP[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS --help $cmdline";
	executeCommand('RESULT', undef, $cmdId, $cmdline, $fullCmdline);
}

sub registerCheckCommand {
	my ($cmdId, $instanceId, $cmdline)=@_;
	print "REGISTER[$cmdId]: '$instanceId'=$cmdline";
	my $config = openOrCreateConfigFile();
	my %instances = $config->addToHash('instances',$instanceId,$cmdline);
	makeServerEventLoop();
	# Envoi un message REGISTERED indiquant la création de l'instance
	sendMessageToServer('REGISTERED', {
		cmdId => $cmdId,
		id => $instanceId,
		cmdline => $cmdline
	});
}

sub unregisterCheckCommand {
	my ($cmdId, $instanceId)=@_;
	print "UNREGISTER[$cmdId]:$instanceId";
	my $config = openOrCreateConfigFile();
	$config->deleteFromHash('instances',$instanceId);
	makeServerEventLoop();
	# Envoi un message UNREGISTERED indiquant la suppression de l'instance
	sendMessageToServer('UNREGISTERED', {
		cmdId => $cmdId,
		id => $instanceId
	});
}

sub getVersion {
	return "DMon client version $VERSION - $^O";
}

sub getHelp {
	my $help=<<EOF;
!check (...)  : Call a check plugin with the given parameters (try --help)
!update       : Download the latest version of the client from github
!reload       : Reload the client (useful after an update)
!version      : Display version of this client ( __VERSION__ )
!help         : Prints this message
EOF
	$help=~s/__VERSION__/getVersion()/e;
	return $help;
}

