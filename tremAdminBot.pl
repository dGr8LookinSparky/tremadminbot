use strict;
use warnings;
use DBI;
use Data::Dumper;
use Geo::IP::PurePerl;
use Socket;
use enum;

# config
our $ip;
our $port;
our $rcpass;
our $log;
our $db;
our $disablerespond;
our $backlog;
do 'config.cfg'; 
my $gi = Geo::IP::PurePerl->open( "/usr/local/share/GeoIP/GeoLiteCity.dat", GEOIP_STANDARD );

# allocate
use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
my @connectedUsers;
for( my $i = 0; $i < 64; $i++ )
{
  push( @connectedUsers, {'connected' => CON_DISCONNECTED} );
}

my $servertsstr;
my $servertsminoff;
my $servertssecoff;

open( FILE, "<",  $log ) or die "open failed";
if( !$backlog )
{
  seek( FILE, 0, 2 ) or die "seek fail";  # need to use 2 instead of SEEK_END. No idea why.
}
while( 1 )
{ 
  if( my $line = <FILE> ) 
  { 
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );
    
    if( $line =~ /^([\d ]{3}):([\d]{2}) ([\w]+): (.*)/ )
    {
      $servertsminoff = $1;
      $servertssecoff = $2;
      my $arg0 = $3;
      my $args = $4;

      #`print "arg0: ${arg0} args: ${args}\n";

      if( $arg0 eq "ClientConnect" )
      {
        if( $args =~ /([\d]+) \[([0-9.]*)\] \(([\w]+)\) \"(.*)\" \"(.*)\"/ )
        {
          my $slot = $1;
          my $ip = $2;
          my $guid = $3;
          my $name = $4;
          my $nameColored = $5;
          my $nameq = lc( $name );
          $nameq = $db->quote( $nameq );
          #print "slot ${slot} ip ${ip} guid ${guid} name ${name}\n";
          my $q = $db->prepare("select * from seen where name = ${nameq}");
          $q->execute;

          $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
          $connectedUsers[ $slot ]{ 'IP' } = $ip;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
          $connectedUsers[ $slot ]{ 'aname' } = "";
          $connectedUsers[ $slot ]{ 'alevel' } = "";

          if( my $ref = $q->fetchrow_hashref( ) )
          {
            $db->do( "UPDATE seen SET time=${timestamp} WHERE name=${nameq}" );
          }
          else
          {
            $db->do( "INSERT INTO seen (name, time) VALUES (${nameq}, ${timestamp})" );
          }
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      if( $arg0 eq "ClientDisconnect" )
      {
        if( $args =~ /^([\d]+)/ )
        {
          my $slot = $1;
          $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientBegin" )
      {
        $args =~ /([\d-]+)/;
        my $slot = $1;
        my $name = $connectedUsers[ $slot ]{ 'name' };
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;
        #`print( "Begin: ${name}\n" );

        if( $connectedUsers[ $slot ]{ 'alevel' } eq "" )
        {
          $connectedUsers[ $slot ]{ 'alevel' } = 0;
        }

        my $memonameq = $db->quote( lc( $name ) );

        my $q = $db->prepare("SELECT * FROM memo WHERE name = ${memonameq}" );
        $q->execute;

        while( my $ref = $q->fetchrow_hashref( ) )
        {
          my $senttime = $ref->{'senttime'};
          my $memo = $ref->{'msg'};
          my $sentby = $ref->{'sentby'};
          replyToPlayer( $slot, "Memo from user ${sentby} [${senttime}]: ${memo}" );
        }
        $db->do( "DELETE FROM memo WHERE name = ${memonameq}" );

        my $aname = $connectedUsers[ $slot ]{ 'aname' };
        if( $aname && lc( $aname ) ne lc( $name ) ) 
        {
          my $memonameq = $db->quote( lc( $aname ) );
          my $q = $db->prepare("SELECT * FROM memo WHERE name = ${memonameq}" );
          $q->execute;

          while( my $ref = $q->fetchrow_hashref( ) )
          {
            my $senttime = $ref->{'senttime'};
            my $memo = $ref->{'msg'};
            my $sentby = $ref->{'sentby'};
            replyToPlayer( $slot, "Memo from user ${sentby} [${senttime}]: ${memo}" );
          }
          $db->do( "DELETE FROM memo WHERE name = ${memonameq}" );
        }
      }
      elsif( $arg0 eq "AdminAuth" )
      {
        if( $args =~/([\d-]+) \"(.+)\" \"(.+)\" \[([\d]+)\] \(([\w]+)\):/ )
        {
          my $slot = $1;
          my $name = $2;
          my $aname = $3;
          my $alevel = $4;
          my $guid = $5;

          #`print "Auth: Slot: ${slot} name: ${name} aname: ${aname} alevel: ${alevel} guid: ${guid}\n";

          $connectedUsers[ $slot ]{ 'aname' } = $aname;
          $connectedUsers[ $slot ]{ 'alevel' } = $alevel;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientRename" )
      {
        if( $args =~ /([\d]+) \[([0-9.]*)\] \(([\w]+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/ )
        {
          my $slot = $1;
          my $ip = $2;
          my $guid = $3;
          my $previousName = $4;
          my $name = $5;
          my $nameColored = $6;

          $connectedUsers[ $slot ]{ 'previousName' } = $previousName;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
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
      elsif( $arg0 eq "Say" || $arg0 eq "SayTeam" || $arg0 eq "AdminMsg" )
      {
        $args =~ /([\d-]+) \"(.+)\": (.*)/;
        my $slot = $1;
        my $player = $2;
        my $said = $3;
    #   print "said: ${said}\n";
        if( $said =~ /fuck you, console/i )
        {
          replyToPlayer( $slot, "No, fuck you, ${player}!" );
        }
      }
      elsif( $arg0 eq "AdminCmd" )
      {
        if( $args =~ /([\d-]+) \"(.*)\" \(\"(.*)\"\) \[([\d]+)\]: ([\w]+) (.*)/ )
        {
          my $slot = $1;
          my $name = $2;
          my $nameq = $db->quote( $name );
          my $aname = $3;
          my $alevel = $4;
          my $acmd = $5;
          $acmd = lc($acmd);
          my $acmdargs = $6;

          #`print "admin command: slot ${slot} name ${name} aname ${aname} acmdargs ${acmd} acmdargs ${acmdargs}\n";

          if( $acmd eq "seen" )
          {
            my $seenstring = $acmdargs;
            print( "Cmd: ${name} /seen ${seenstring}\n" );
            $seenstring = lc( $seenstring );
            my $seenstringq = $db->quote( "\%" . $seenstring . "\%" );
            my $q = $db->prepare("select * from seen where name like ${seenstringq} order by time desc" );
            $q->execute;

            my $rescount = 0;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              last if( $rescount > 3 );
              my $seenname = $ref->{'name'};
              my $seentime = $ref->{'time'};
              replyToPlayer( $slot, "seen: User ${seenname} last seen: ${seentime}" );
              ++$rescount;
            }

            my $ref = $q->fetchrow_hashref( );
            if( $rescount > 0 && $ref )
            {
              replyToPlayer( $slot, "seen: Too many results to display. Try a more specific query." );
            }
            elsif( $rescount == 0 )
            {
              replyToPlayer( $slot, "seen: User ${seenstring} not found" );
            }
          }
          elsif( $acmd eq "memo" )
          {
            if( $acmdargs =~ /([^ ]+|"[.]+") (.*)/)
            {
              my $memoname = lc( $1 );
              $memoname =~ s/\"//g;
              my $memonameq = $db->quote( $memoname );
              my $memo = $2;
              my $memoq = $db->quote( $memo );

              print( "Cmd: ${name} /memo ${memoname} ${memo}\n" );
              $db->do( "INSERT INTO memo (name, sentby, senttime, msg) VALUES (${memonameq}, ${nameq}, ${timestamp}, ${memoq})" );
              replyToPlayer( $slot, "memo: memo left for ${memoname}" );
            }
            else
            {
              print( "Parse failure on ${acmd} ${acmdargs}\n" );
            }
          }
          elsif( $acmd eq "geoip" )
          {
            my $gipip;
            my $gipname;
            print( "Cmd: ${name} /geoip ${acmdargs}\n" );

            if( $acmdargs =~ /^([\d]+)$/ )
            {
              my $gipslot = $1;
              if( $gipslot < 64 && $connectedUsers[ $gipslot ]{ 'IP' } )
              {
                $gipip = $connectedUsers[ $gipslot ]{ 'IP' };
                $gipname = $connectedUsers[ $gipslot ]{ 'name' };
              }
              else
              {
                replyToPlayer( $slot, "geoip: invalid or unused slot #${gipslot}" );
                next;
              }
            }
            elsif( $acmdargs =~ /([0-9.]+)/ )
            {
              $gipip = $gipname = $1;
            }
            else
            {
              replyToPlayer( $slot, "geoip: usage: geoip <slot#|IP>" );
              next;
            }
            my $gipinfo = $gi->get_city_record_as_hash( $gipip );
            my $gipcountry = $$gipinfo{ 'country_name' };
            my $gipcity = $$gipinfo{ 'city' };
            my $gipregion = $$gipinfo{ 'region' };
            my $gipiaddr = inet_aton( $gipip );
            my $giphostname = gethostbyaddr( $gipiaddr, AF_INET );
            replyToPlayer( $slot, "geoip: ${gipname} connecting from ${giphostname} ${gipcity} ${gipregion} ${gipcountry}" );
          }
          elsif( $acmd eq "l1" )
          {
            if( $acmdargs =~ /^([\d]+)$/ )
            {
              my $targslot = $1;

              print( "Cmd: ${name} /l1 ${acmdargs}\n" );
              if( $targslot < 64 && 
                  $connectedUsers[ $targslot ]{ 'connected' } == CON_CONNECTED && 
                  $connectedUsers[ $targslot ]{ 'IP' } )
              {
                if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
                {
                  printToPlayers( "l1: ${name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
                  sendconsole( "setlevel ${targslot} 1" );
                }
                else
                {
                  replyToPlayer( $slot, "l1: User #${targslot} is not level 0" );
                  next;
                }
              }
              else
              {
                replyToPlayer( $slot, "l1: invalid or unused slot #${targslot}" );
                next;
              }
            }
            else
            {
              replyToPlayer( $slot, "l1: usage: l1 <slot# of level 0 user>" );
              next;
            }
          }
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
    }
  }
  else
  { 
    if( $backlog )
    {
      print "End of backlog\n";
      exit;
    }
    seek( FILE, 0, 1 ); 
    sleep 1; 
  }
}

close( FILE );

sub replyToPlayer
{
  my $slot = shift;
  my $string = shift;

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
  my $string = shift;
  sendconsole( "pr -1 ${string}" );
}


sub sendconsole
{
  my $string = shift;
  if( $disablerespond || $backlog )
  {
    return;
  }

  $string =~ s/'//g;
# `screen -S tremded -p 0 -X stuff $\'\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10${string}\n\'`

  my $outstring = `echo -e \'\xff\xff\xff\xffrcon ${rcpass} ${string}\' | nc -w 0 -u ${ip} ${port}`;
  if( $outstring )
  {
    #print "Output: $outstring";
  }
  print "Sent: ${string}\n";
  return $outstring;
}

sub timestamp
{
  if( $backlog )
  {
    my $out = $servertsstr;
    $out =~ s/\//-/g;
    return( $db->quote( $out ) );
  }
  my $q = $db->prepare( "select DATETIME('now','localtime')" );
  $q->execute;
  my $out = $q->fetchrow_array( );

  $out = $db->quote( $out );
  return $out;
}
