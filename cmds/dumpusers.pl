use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $q = $db->prepare( 'SELECT * FROM users' );
  $q->execute;
  while( my $r = $q->fetchrow_hashref )
  {
    replyToPlayer( $_[ 0 ], "  userID=$r->{ userID }; name=$r->{ name }; useCount=$r->{ useCount }; seenTime=$r->{ seenTime }; IP=$r->{ IP }; city=$r->{ city }; region=$r->{ region }; country=$r->{ country }" );
  }
};
