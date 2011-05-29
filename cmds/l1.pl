use common::sense;
our @connectedUsers;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /l1 ${acmdargs}\n" );

  my $targslot;

  if( $user->{ 'alevel' } == 0 )
  {
    $targslot = $user->{ 'slot' };
  }
  elsif( $acmdargs eq "" )
  {
    replyToPlayer( $user, "^3l1:^7 usage: l1 <name|slot#>" );
    return;
  }
  else
  {
    my $err = "";
    $targslot = slotFromString( $acmdargs, 1, \$err );
    if( $targslot < 0 )
    {
      replyToPlayer( $user, "^3l1:^7 ${err}" );
      return;
    }
  }

  if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
  {
    printToPlayers( "^3l1:^7 $user->{name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
    sendconsole( "setlevel ${targslot} 1" );
  }
  else
  {
    replyToPlayer( $user, "^3l1:^7 User #${targslot} is not level 0" );
    return;
  }
};
