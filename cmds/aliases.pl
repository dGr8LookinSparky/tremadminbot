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

  if( $acmdargs->[ 0 ] eq "" )
  {
    replyToPlayer( $user, "^3aliases:^7 usage: aliases <name|slot#>" );
    return;
  }

  my $err = "";
  my $targslot = slotFromString( $acmdargs->[ 0 ], 1, \$err );
  if( $targslot < 0 )
  {
    replyToPlayer( $user, "^3aliases:^7 ${err}" );
    return;
  }

  my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
  my $namesq = $db->prepare( "SELECT nameColored FROM names WHERE userID = ${targUserID} ORDER BY useCount DESC LIMIT 15" );
  $namesq->execute;

  my @aliases;
  while( my $ref = $namesq->fetchrow_hashref( ) )
  {
    push( @aliases, $ref->{ 'nameColored' } );
  }
  push( @aliases, $user->{ 'nameColored' } ) if( !scalar @aliases );
  my $count = scalar @aliases;

  replyToPlayer( $user, "^3aliases:^7 ${count} names found: " . join( "^3,^7 ", @aliases ) ) if( $count );
};
