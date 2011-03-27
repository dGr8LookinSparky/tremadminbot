use strict;
use warnings;
use DBI;
use Data::Dumper;
use Geo::IP::PurePerl;
use Socket;
use enum;
use FileHandle;
use File::ReadBackwards;


use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
use enum qw( SEND_DISABLE SEND_PIPE SEND_RCON SEND_SCREEN );

# config: best to leave these defaults alone and set each var you want to override from default in config.cfg
#         e.g. if you want to change $logpath, put a line that says
#              $logpath = "/somewherelse/games.log";
#              in config.cfg

# Path to games.log
our $logpath = "games.log";

# Where do we store the database
our $dbfile = "bot.db";

# Are we reading from the whole logfile to populate the db? Generally this is 0
our $backlog = 0;

# How should we send output responses back to the server?
#  SEND_DISABLE: Do not send output responses back to the server.
#  SEND_PIPE:    Write to a pipefile, as configured by the com_pipefile option. Best option if available.
#                Fast and robust.
#  SEND_RCON:    Use rcon. Requires netcat, ideally a freeBSD netcat.
#                The only option that can get a response back from commands, but we don't use that anyway.
#                Slow and shows up in log files as rcon usage.
#  SEND_SCREEN:  Send a command to the screen session tremded is running in.
#                Very annoying if humans also attach to and use screen.
our $sendMethod = SEND_PIPE;

# rcon password, only used for SEND_RCON
our $rcpass = "myrconpassword";

# server ip, only used for SEND_RCON
our $ip = "127.0.0.1";

# server port, only used for SEND_RCON
our $port = "30720";

#  path to communication pipe to write to, only used for SEND_PIPE
our $pipefilePath = ".tremded_pipe";

# name of screen session, only used for SEND_SCREEN
our $screenName = "tremded";

# CONFIG STUFF ENDS HERE
do 'config.cfg';



$SIG{INT} = \&cleanup;
$SIG{__DIE__} = \&errorHandler;

my $gi = Geo::IP::PurePerl->open( "/usr/local/share/GeoIP/GeoLiteCity.dat", GEOIP_STANDARD );
my $db = DBI->connect( "dbi:SQLite:${dbfile}", "", "", {RaiseError => 1, AutoCommit => 1} ) or die "Database error: " . $DBI::errstr;

# allocate
my @connectedUsers;
for( my $i = 0; $i < 64; $i++ )
{
  push( @connectedUsers, {'connected' => CON_DISCONNECTED} );
}

my $servertsstr;
my $servertsminoff;
my $servertssecoff;

my $lineRegExp = qr/^([\d ]{3}):([\d]{2}) ([\w]+): (.*)/;
my $clientConnectRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" \"(.*)\"/;
my $clientDisconnectRegExp = qr/^([\d]+)/;
my $clientBeginRegExp = qr/^([\d-]+)/;
my $adminAuthRegExp = qr/^([\d-]+) \"(.+)\" \"(.+)\" \[([\d]+)\] \(([\w]+)\):/;
my $clientRenameRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/;
my $sayRegExp = qr/^([\d-]+) \"(.+)\": (.*)/;
my $adminCmdRegExp = qr/^([\d-]+) \"(.*)\" \(\"(.*)\"\) \[([\d]+)\]: ([\w]+) (.*)/;
my $nameRegExpUnquoted= qr/.+/;
my $nameRegExpQuoted = qr/\".+\"/;
my $nameRegExp = qr/${nameRegExpQuoted}|${nameRegExpUnquoted}/;

my $startupBacklog = 1;

open( FILE, "<",  $logpath ) or die "open logfile failed: ${logpath}";
if( $sendMethod == SEND_PIPE )
{
  die( "Could not open pipefile ${pipefilePath}. Is tremded running?" ) if( !-e $pipefilePath );
  open( SENDPIPE, ">", $pipefilePath );
  SENDPIPE->autoflush( 1 );
}

if( !$backlog ) # Seek back to the start of the current game game
{
  my $bw = File::ReadBackwards->new( $logpath );
  my $seekPos = 0;

  while( defined( my $line = $bw->readline( ) ) )
  {
    if( $line =~ /$lineRegExp/ )
    {
      my $arg0 = $3;
      if( $arg0 eq "InitGame" )
      {
        $seekPos = $bw->tell( );
        last( );
      }
    }
  }

  if( $seekPos )
  {
    seek( FILE, $seekPos, 0 ) or die "seek fail";
  }
  else
  {
    seek( FILE, 0, 2 ) or die "seek fail";  # need to use 2 instead of SEEK_END. No idea why.
  }
}

while( 1 )
{
  if( my $line = <FILE> )
  {
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );

    if( ( $servertsminoff, $servertssecoff, my $arg0, my $args ) = $line =~ /$lineRegExp/ )
    {

      #`print "arg0: ${arg0} args: ${args}\n";

      if( $arg0 eq "ClientConnect" )
      {
        if( my ( $slot, $ip, $guid, $name, $nameColored ) = $args =~ /$clientConnectRegExp/ )
        {
          #print "slot ${slot} ip ${ip} guid ${guid} name ${name}\n";

          $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
          $connectedUsers[ $slot ]{ 'IP' } = $ip;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
          $connectedUsers[ $slot ]{ 'aname' } = "";
          $connectedUsers[ $slot ]{ 'alevel' } = "";

          $connectedUsers[ $slot ]{ 'IP' } ||= "127.0.0.1";

          updateUsers( $timestamp, $slot );
          next if( $startupBacklog );
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientDisconnect" )
      {
        if( my ( $slot ) = $args =~ /$clientDisconnectRegExp/ )
        {
          $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientBegin" )
      {
        my ( $slot ) = $args =~ /$clientBeginRegExp/;
        my $name = $connectedUsers[ $slot ]{ 'name' };
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;
        #`print( "Begin: ${name}\n" );

        $connectedUsers[ $slot ]{ 'alevel' } ||= 0;

        next if( $startupBacklog );

        memocheck( $slot, $timestamp );

      }
      elsif( $arg0 eq "AdminAuth" )
      {
        if( my ( $slot, $name, $aname, $alevel, $guid ) = $args =~ /$adminAuthRegExp/ )
        {
          #`print "Auth: Slot: ${slot} name: ${name} aname: ${aname} alevel: ${alevel} guid: ${guid}\n";

          $connectedUsers[ $slot ]{ 'aname' } = $aname;
          $connectedUsers[ $slot ]{ 'alevel' } = $alevel;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
          my $userID = $connectedUsers[ $slot ]{ 'userID' };

          my $anameq = $db->quote( $aname );

          $db->do( "UPDATE users SET name=${anameq}, adminLevel=$alevel WHERE userID=${userID}" );
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientRename" )
      {
        if( my ( $slot, $ip, $guid, $previousName, $name, $nameColored ) = $args =~ /$clientRenameRegExp/ )
        {
          $connectedUsers[ $slot ]{ 'previousName' } = $previousName;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;

          updateNames( $timestamp, $slot );
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "RealTime" )
      {
        $servertsstr = $args;
      }

      next if( $startupBacklog );

      if( $arg0 eq "AdminCmd" )
      {
        if( my( $slot, $name, $aname, $alevel, $acmd, $acmdargs ) = $args =~ /$adminCmdRegExp/ )
        {
          my $nameq = $db->quote( $name );
          $acmd = lc($acmd);
          my $guid;

          if( $slot != -1 )
          {
            $guid = $connectedUsers[ $slot ]{ 'GUID' };
          }
          else
          {
            $guid = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
          }

          my $userID = $connectedUsers[ $slot ]{ 'userID' };

          #`print "admin command: slot ${slot} name ${name} aname ${aname} acmdargs ${acmd} acmdargs ${acmdargs}\n";

          if( $acmd eq "seen" )
          {
            my $seenstring = $acmdargs;
            print( "Cmd: ${name} /seen ${seenstring}\n" );
            $seenstring = lc( $seenstring );
            my $seenstringq = $db->quote( "\%" . $seenstring . "\%" );
            my $q = $db->prepare( "SELECT name, seenTime, useCount FROM names WHERE name like ${seenstringq} ORDER BY useCount DESC" );
            $q->execute;

            my $rescount = 0;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              last if( $rescount > 3 );
              my $seenname = $ref->{'name'};
              my $seentime = $ref->{'seenTime'};
              my $seencount = $ref->{'useCount'};
              replyToPlayer( $slot, "^3seen:^7 Username ${seenname} seen ${seencount} times, last: ${seentime}" );
              ++$rescount;
            }

            my $ref = $q->fetchrow_hashref( );
            if( $rescount > 0 && $ref )
            {
              replyToPlayer( $slot, "^3seen:^7 Too many results to display. Try a more specific query." );
            }
            elsif( $rescount == 0 )
            {
              replyToPlayer( $slot, "^3seen:^7 Username ${seenstring} not found" );
            }
          }
          elsif( $acmd eq "memo" )
          {
            if( $acmdargs =~ /^([\w]+)/ )
            {
              my $memocmd = lc( $1 );
              print( "Cmd: ${name} /memo ${acmdargs}\n" );

              if( $memocmd eq "send" )
              {
                if( $acmdargs =~ /^([\w]+) ($nameRegExp) (.*)/ )
                {
                  my $memoname = lc( $2 );
                  my $memo = $3;
                  my $memoq = $db->quote( $memo );

                  $memoname =~ s/\"//g;
                  my $memonamelq = $db->quote( "\%" . $memoname . "\%" );

                  my $q = $db->prepare( "SELECT users.userID, names.name, names.nameColored FROM users LEFT JOIN names ON names.userID = users.userID WHERE names.name LIKE ${memonamelq} AND users.seenTime > datetime( ${timestamp}, \'-3 months\')" );
                  $q->execute;

                  my @matches;
                  my $lastmatch;
                  my $exact = 0;
                  my $i = 0;
                  while( my $ref = $q->fetchrow_hashref( ) )
                  {
                    $exact = $i if( $ref->{ 'name' } eq $memoname );
                    $lastmatch = $ref->{ 'userID' };
                    push( @matches, $ref->{ 'nameColored' } );
                    last if( $exact );
                    $i++;
                  }

                  if( $exact )
                  {
                    my $memonameq = $db->quote( $memoname );
                    $db->do( "INSERT INTO memos (userID, sentBy, sentTime, msg) VALUES (${lastmatch}, ${userID}, ${timestamp}, ${memoq})" );
                    replyToPlayer( $slot, "^3memo:^7 memo left for ${matches[ $exact ]}" );
                  }
                  elsif( scalar @matches == 1 )
                  {
                    my $memonameq = $db->quote( $lastmatch );
                    $db->do( "INSERT INTO memos (userID, sentBy, sentTime, msg) VALUES (${lastmatch}, ${userID}, ${timestamp}, ${memoq})" );
                    replyToPlayer( $slot, "^3memo:^7 memo left for ${matches[ 0 ]}" );
                  }
                  elsif( scalar @matches > 1 )
                  {
                    replyToPlayer( $slot, "^3memo:^7 multiple matches. Be more specific: " . join( ", ", @matches ) );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7 invalid user: ${memoname} not seen in last 3 months." );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo send <name> <message>" );
                }
              }
              elsif( $memocmd eq "list" )
              {
                my $q = $db->prepare( "SELECT memos.memoID, memos.readTime, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.userID = ${userID} ORDER BY memoID ASC" );
                $q->execute;

                my @memos;
                my @readMemos;
                while( my $ref = $q->fetchrow_hashref( ) )
                {
                  my $name = $ref->{ 'name' };
                  my $readTime = $ref->{ 'readTime' };
                  my $memoID = $ref->{ 'memoID' };

                  if( $readTime )
                  {
                    push( @readMemos, ${memoID} );
                  }
                  else
                  {
                    push( @memos, ${memoID} );
                  }
                }
                my $newCount = scalar @memos;
                my $readCount = scalar @readMemos;
                replyToPlayer( $slot, "^3memo:^7 You have ${newCount} new Memos: " . join( ", ", @memos ) . ". Use /memo read <memoID>" ) if( $newCount );
                replyToPlayer( $slot, "^3memo:^7 You have ${readCount} read Memos: " . join( ", ", @readMemos ) ) if( $readCount );
                replyToPlayer( $slot, "^3memo:^7 You have no memos." ) if( !$newCount && !$readCount );
              }

              elsif( $memocmd eq "read" )
              {
                if( $acmdargs =~ /^([\w]+) ([\d]+)/ )
                {
                  my $memoID = $2;
                  my $memoIDq = $db->quote( $memoID );

                  my $q = $db->prepare( "SELECT memos.memoID, memos.sentTime, memos.msg, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.memoID = ${memoIDq} AND memos.userID = ${userID}" );
                  $q->execute;
                  if( my $ref = $q->fetchrow_hashref( ) )
                  {
                    my $id = $ref->{ 'memoID' };
                    my $from = $ref->{ 'name' };
                    my $sentTime = $ref->{ 'sentTime' };
                    my $msg = $ref->{ 'msg' };

                    replyToPlayer( $slot, "Memo: ${id} From: ${from} Sent: ${sentTime}" );
                    replyToPlayer( $slot, " Msg: ${msg}" );

                    $db->do( "UPDATE memos SET readTime=${timestamp} WHERE memoID=${memoIDq}" );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7: Invalid memoID: ${memoID}" );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo read <memoID>" );
                }
              }
              elsif( $memocmd eq "outbox" )
              {
                my $q = $db->prepare( "SELECT memos.memoID, users.name FROM memos JOIN users ON users.userID = memos.userID WHERE memos.sentBy = ${userID} AND memos.readTime IS NULL ORDER BY memoID ASC" );
                $q->execute;

                my @memos;
                while( my $ref = $q->fetchrow_hashref( ) )
                {
                  my $name = $ref->{ 'name' };
                  my $memoID = $ref->{ 'memoID' };

                  push( @memos, "ID: ${memoID} To: ${name}" );
                }
                replyToPlayer( $slot, "^3memo:^7 Unread Sent Memos: " . join( ", ", @memos ) ) if( scalar @memos );
                replyToPlayer( $slot, "^3memo:^7 You have no unread sent memos." ) if( ! scalar @memos );
              }
              elsif( $memocmd eq "unsend" )
              {
                if( $acmdargs =~ /^([\w]+) ([\d]+)/ )
                {
                  my $memoID = $2;
                  my $memoIDq = $db->quote( $memoID );

                  my $count = $db->do( "DELETE FROM memos WHERE sentBy = ${userID} AND memoID = ${memoIDq}" );
                  if( $count ne "0E0" )
                  {
                    replyToPlayer( $slot, "^3memo:^7 deleted sent memo ${memoID}" );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7 invalid memoID ${memoID}" );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo unsend <memoID>" );
                }
              }
              elsif( $memocmd eq "clear" )
              {
                if( $acmdargs =~ /^([\w]+) ([\w]+)/ )
                {
                  my $clearcmd = lc( $2 );

                  if( $clearcmd eq "all" )
                  {
                    my $count = $db->do( "DELETE FROM memos WHERE userID = ${userID}" );
                    replyToPlayer( $slot, "^3memo:^7 cleared ${count} memos" );
                  }
                  elsif( $clearcmd eq "read" )
                  {
                    my $count = $db->do( "DELETE FROM memos WHERE userID = ${userID} AND readTime IS NOT NULL" );
                    replyToPlayer( $slot, "^3memo:^7 cleared ${count} read memos" );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7 syntax: memo clear <ALL|READ>" );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo clear <ALL|READ>" );
                }
              }
              else
              {
                replyToPlayer( $slot, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
              }
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
            }
          }
          elsif( $acmd eq "geoip" )
          {
            my $gipip;
            my $gipname;
            print( "Cmd: ${name} /geoip ${acmdargs}\n" );

            if( $acmdargs =~ /^([\d]+\.[\d]+\.[\d]+\.[\d]+)/ )
            {
              $gipip = $gipname = $1;
            }
            elsif( $acmdargs =~ /^($nameRegExp)/ )
            {
              my $giptarg = $1;
              my $err = "";
              my $gipslot = slotFromString( $giptarg, 0, \$err );
              if( $gipslot < 0 )
              {
                replyToPlayer( $slot, "^3geoip:^7 ${err}" );
                next;
              }

              if( $connectedUsers[ $gipslot ]{ 'IP' } )
              {
                $gipip = $connectedUsers[ $gipslot ]{ 'IP' };
                $gipname = $connectedUsers[ $gipslot ]{ 'name' };
              }
              else
              {
                replyToPlayer( $slot, "^3geoip:^7 Unused slot #${giptarg}" );
                next;
              }
            }
            else
            {
              replyToPlayer( $slot, "^3geoip:^7 usage: geoip <name|slot#|IP>" );
              next;
            }
            my $gipinfo = $gi->get_city_record_as_hash( $gipip );
            my $gipcountry = $$gipinfo{ 'country_name' };
            my $gipcity = $$gipinfo{ 'city' };
            my $gipregion = $$gipinfo{ 'region' };
            my $gipiaddr = inet_aton( $gipip );
            my $giphostname = gethostbyaddr( $gipiaddr, AF_INET );
            $gipcountry ||= "";
            $gipcity ||= "";
            $gipregion ||= "";
            replyToPlayer( $slot, "^3geoip:^7 ${gipname} connecting from ${giphostname} ${gipcity} ${gipregion} ${gipcountry}" );
          }
          elsif( $acmd eq "l1" )
          {
            print( "Cmd: ${name} /l1 ${acmdargs}\n" );

            my $err = "";
            my $targslot = slotFromString( $acmdargs, 1, \$err );
            if( $targslot < 0 )
            {
              replyToPlayer( $slot, "^3l1:^7 ${err}" );
              next;
            }

            if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
            {
              printToPlayers( "^3l1:^7 ${name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
              sendconsole( "setlevel ${targslot} 1" );
            }
            else
            {
              replyToPlayer( $slot, "^3l1:^7 User #${targslot} is not level 0" );
              next;
            }
          }
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      #`elsif( $arg0 eq "Say" || $arg0 eq "SayTeam" || $arg0 eq "AdminMsg" )
      #`{
        #`$args =~ /$sayRegExp/;
        #`my $slot = $1;
        #`my $player = $2;
        #`my $said = $3;
        #`if( $said =~ /hi console/i )
        #`{
          #`replyToPlayer( $slot, "Hi ${player}!" );
        #`}
      #`}
    }
  }
  else
  {
    if( $backlog )
    {
      print "End of backlog\n";
      exit;
    }

    if( $startupBacklog )
    {
      $startupBacklog = 0;
    }

    seek( FILE, 0, 1 );
    sleep 1;
  }
}

sub replyToPlayer
{
  my( $slot, $string ) = @_;

  if( $slot > 0 )
  {
    sendconsole( "pr ${slot} ${string}" );
  }
  else
  {
    sendconsole( "echo ${string}" );
  }
}

sub printToPlayers
{
  my( $string ) = @_;
  sendconsole( "pr -1 ${string}" );
}

sub sendconsole
{
  my( $string ) = @_;
  return if( $backlog || $startupBacklog || $sendMethod == SEND_DISABLE );

  $string =~ s/'//g;
  my $outstring = "";

  if( $sendMethod == SEND_PIPE )
  {
    print( SENDPIPE "${string}\n" ) or die "Broken pipe!";
  }
  elsif( $sendMethod == SEND_RCON )
  {
    $outstring = `echo -e \'\xff\xff\xff\xffrcon ${rcpass} ${string}\' | nc -w 0 -u ${ip} ${port}`;
  }
  elsif( $sendMethod == SEND_SCREEN )
  {
    `screen -S ${screenName} -p 0 -X stuff $\'\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10${string}\n\'`
  }
  else
  {
    die "Invalid $sendMethod configured";
  }

  if( $outstring )
  {
    #print "Output: $outstring";
  }
  print "Sent: ${string}\n";
  return $outstring;
}

sub updateUsers
{
  my( $timestamp, $slot ) = @_;
  my $guid = $connectedUsers[ $slot ]{ 'GUID' };
  my $guidq = $db->quote( $guid );
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $ip = $connectedUsers[ $slot ]{ 'IP' };
  my $ipq = $db->quote( $ip );

  my $region = "";
  my $regionq = $db->quote( $region );
  my $country = "";
  my $countryq = $db->quote( $country );

  my $usersq = $db->prepare( "SELECT * FROM users WHERE GUID = ${guidq}" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  { }
  else
  {
    $db->do( "INSERT INTO users ( name, GUID, useCount, seenTime, IP, adminLevel, region, country ) VALUES ( ${nameq}, ${guidq}, 0, ${timestamp}, ${ipq}, 0, ${regionq}, ${countryq} )" );
    $usersq->execute;
    $user = $usersq->fetchrow_hashref( );
  }

  my $userID = $user->{ 'userID' };
  my $adminLevel = $user->{ 'adminLevel' };
  $connectedUsers[ $slot ]{ 'userID' } = $userID;

  return if( $startupBacklog );

  updateNames( $timestamp, $slot );

  if( !$adminLevel )
  {
    $db->do( "UPDATE users SET name=${nameq}, useCount=useCount+1, seenTime=${timestamp}, ip=${ipq}, region=${regionq}, country=${countryq} WHERE userID=${userID}" );
  }
  else
  {
    $db->do( "UPDATE users SET useCount=useCount+1, seenTime=${timestamp}, ip=${ipq}, region=${regionq}, country=${countryq} WHERE userID=${userID}" );
  }
}

sub updateNames
{
  my( $timestamp, $slot ) = @_;
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $namec = $connectedUsers[ $slot ]{ 'nameColored' };
  my $namecq = $db->quote( $namec );
  my $userID = $connectedUsers[ $slot ]{ 'userID' };

  my $namesq = $db->prepare( "SELECT * FROM names WHERE name = ${nameq}" );
  $namesq->execute;

  my $namesref;

  if( my $ref = $namesq->fetchrow_hashref( ) )
  { }
  else
  {
    $db->do( "INSERT INTO names ( name, nameColored, userID, useCount, seenTime ) VALUES ( ${nameq}, ${namecq}, ${userID}, 0, ${timestamp} )" );
  }

  return if( $startupBacklog );

  $db->do( "UPDATE names SET usecount=useCount+1, seenTime=${timestamp}, userID=${userID} WHERE name = ${nameq}" );
}

sub memocheck
{
  my( $slot, $timestamp ) = @_;
  my $name = $connectedUsers[ $slot ]{ 'name' };
  my $userID = $connectedUsers[ $slot ]{ 'userID' };

  my $q = $db->prepare( "SELECT COUNT(1) FROM memos WHERE memos.userID = ${userID} AND memos.readTime IS NULL" );
  $q->execute;

  my $ref = $q->fetchrow_hashref( );
  my $count = $ref->{ 'COUNT(1)' };

  replyToPlayer( $slot, "You have ${count} new memos. Use /memo list to read." ) if $count > 0;

}

sub slotFromString
{
  my ( $string, $requireConnected, $err ) = @_;
  $string = lc( $string );

  if( $string =~ /^[\d]+/ )
  {
    if( $string >= 64 )
    {
      $$err = "Invalid slot #${string}";
      return( -1 );
    }

    if( $requireConnected && $connectedUsers[ $string ]{ 'connected' } != CON_CONNECTED )
    {
      $$err = "Slot #${string} is not connected";
      return( -1 );
    }
    return $string;
  }

  my $exact = -1;
  my @matches;
  for( my $i = 0; $i < 64; $i++ )
  {
    my $uname = $connectedUsers[ $i ]{ 'name' };
    next if( !$uname );

    next if( $requireConnected && $connectedUsers[ $i ]{ 'connected' } != CON_CONNECTED );

    $exact = $i if( lc( $uname ) eq $string );

    push( @matches, $i ) if( $uname =~ /$string/ );
  }

  my $n = scalar @matches;
  if( $exact >= 0 )
  {
    return $exact;
  }
  elsif( $n == 1 )
  {
    return $matches[ 0 ];
  }
  elsif( $n > 0 )
  {
    $$err = "Multiple name matches. Be more specific or use a slot number";
    return( -1 );
  }
  else
  {
    $$err = "No matches for ${string}";
    return( -1 );
  }
}

sub timestamp
{
  if( $backlog )
  {
    my $out = $servertsstr;
    $out =~ s/\//-/g;
    return( $db->quote( $out ) );
  }
  my $q = $db->prepare( "SELECT DATETIME('now','localtime')" );
  $q->execute;
  my $out = $q->fetchrow_array( );

  $out = $db->quote( $out );
  return $out;
}

sub errorHandler
{
  print "Error: $_[ 0 ]";
  cleanup( );
}

sub cleanup
{
  close( FILE );
  close( SENDPIPE ) if( $sendMethod == SEND_PIPE );
  $db->disconnect( ) or warn( "Disconnection failed: $DBI::errstr\n" );
  exit;
}
