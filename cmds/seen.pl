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

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $seenstring = $acmdargs;

  if( $acmdargs eq "" )
  {
    replyToPlayer( $user, "^3seen:^7 usage: seen <name>" );
    return;
  }

  $seenstring = lc( $seenstring );
  my $seenstringq = $db->quote( $seenstring );
  my $seenstringlq = $db->quote( "\%" . $seenstring . "\%" );
  my $q = $db->prepare( "SELECT userID, name, useCount FROM names WHERE name like ${seenstringlq} ORDER BY CASE WHEN name = ${seenstringq} THEN 999999 else useCount END DESC LIMIT 4" );
  $q->execute;

  my $rescount = 0;
  while( my $ref = $q->fetchrow_hashref( ) )
  {
    my $userID = $ref->{'userID'};
    $q = $db->prepare( "SELECT name, seenTime FROM users WHERE userID = $userID" );
    $q->execute;
    my $u = $q->fetchrow_hashref;
    my $seenname = $ref->{'name'};
    my $realname = $u->{'name'};
    my $seentime = $u->{'seenTime'};
    my $seencount = $ref->{'useCount'};
    replyToPlayer( $user, "^3seen:^7 Player ${seenname} ($realname #$userID) seen ${seencount} times, last: ${seentime}" );
    ++$rescount;
    last if( $rescount > 2 );
  }

  my $ref = $q->fetchrow_hashref( );
  if( $rescount > 0 && $ref )
  {
    replyToPlayer( $user, "^3seen:^7 Too many results to display. Try a more specific query." );
  }
  elsif( $rescount == 0 )
  {
    replyToPlayer( $user, "^3seen:^7 Player ${seenstring} not found" );
  }
};
