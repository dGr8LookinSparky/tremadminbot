use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $seenstring = $acmdargs;
  print( "Cmd: $user->{name} /seen ${seenstring}\n" );

  if( $acmdargs eq "" )
  {
    replyToPlayer( $user, "^3seen:^7 usage: seen <name>" );
    next;
  }

  $seenstring = lc( $seenstring );
  my $seenstringq = $db->quote( $seenstring );
  my $seenstringlq = $db->quote( "\%" . $seenstring . "\%" );
  my $q = $db->prepare( "SELECT name, seenTime, useCount FROM names WHERE name like ${seenstringlq} ORDER BY CASE WHEN name = ${seenstringq} THEN 999999 else useCount END DESC LIMIT 4" );
  $q->execute;

  my $rescount = 0;
  while( my $ref = $q->fetchrow_hashref( ) )
  {
    my $seenname = $ref->{'name'};
    my $seentime = $ref->{'seenTime'};
    my $seencount = $ref->{'useCount'};
    replyToPlayer( $user, "^3seen:^7 Player ${seenname} seen ${seencount} times, last: ${seentime}" );
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
