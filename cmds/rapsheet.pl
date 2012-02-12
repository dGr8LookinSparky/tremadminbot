#    TremAdminBot: A bot that provides some helper functions for Tremulous server administration
#    By Chris "Lakitu7" Schwarz, lakitu7@mercenariesguild.net
#
#    This file is part of TremAdminBot
#
#    TremAdminBot is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    TremAdminBot is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with TremAdminBot.  If not, see <http://www.gnu.org/licenses/>.
use common::sense;
our @connectedUsers;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my( $targ, $param ) = @$acmdargs;
  if( $targ eq "" )
  {
    replyToPlayer( $user, "^3rapsheet:^7 usage: rapsheet <name|slot#> [GUID|IP|SUBNET]" );
    return;
  }

  my $err = "";
  my $targslot = slotFromString( $targ, 1, \$err );
  if( $targslot < 0 )
  {
    replyToPlayer( $user, "^3rapsheet:^7 ${err}" );
    return;
  }

  my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
  my $targName = $connectedUsers[ $targslot ]{ 'nameColored' };
  my $targIP = $connectedUsers[ $targslot ]{ 'IP' };

  my $searchtype;
  my $target;
  if( lc( $param ) eq "ip" || lc( $param ) eq "subnet" )
  {
    $searchtype = uc( $param );
    $target = $targIP;
  }
  else
  {
    $searchtype = "userID";
    $target = $targUserID;
  }

  my $err;
  my @demerits = demerits( $searchtype, $target, \$err );
  unless( @demerits )
  {
    replyToPlayer( $user, "^3rapsheet: ^7$err" );
    return;
  }

  replyToPlayer( $user, "^3rapsheet:^7 ${targName}^7 offenses by ${searchtype}: Kicks: $demerits[ DEM_KICK ] Bans: $demerits[ DEM_BAN ] Mutes: $demerits[ DEM_MUTE ] Denybuilds: $demerits[ DEM_DENYBUILD ]" );
};
