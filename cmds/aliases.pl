use common::sense;
our @connectedUsers;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /aliases @$acmdargs\n" );

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
