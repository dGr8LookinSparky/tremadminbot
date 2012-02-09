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

  print( "Cmd: $user->{name} /l1 @$acmdargs\n" );

  my $targslot;

  if( $user->{ 'alevel' } == 0 )
  {
    $targslot = $user->{ 'slot' };
  }
  elsif( $acmdargs->[ 0 ] eq "" )
  {
    replyToPlayer( $user, "^3l1:^7 usage: l1 <name|slot#>" );
    return;
  }
  else
  {
    my $err = "";
    $targslot = slotFromString( $acmdargs->[ 0 ], 1, \$err );
    if( $targslot < 0 )
    {
      replyToPlayer( $user, "^3l1:^7 ${err}" );
      return;
    }
  }

  if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
  {
    printToPlayers( "^3l1:^7 $user->{name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
    sendconsole( "setlevel ${targslot} 1", PRIO_COMMAND );
  }
  else
  {
    replyToPlayer( $user, "^3l1:^7 User #${targslot} is not level 0" );
    return;
  }
};
