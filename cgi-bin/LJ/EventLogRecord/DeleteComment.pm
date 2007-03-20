package LJ::EventLogRecord::DeleteComment;

use strict;
use base 'LJ::EventLogRecord';
use Carp qw (croak);

sub new {
    my ($class, $cmt) = @_;

    croak "Must pass an LJ::Comment"
        unless UNIVERSAL::isa($e, 'LJ::Comment');

    return $class->SUPER::new(
                              journalid => $cmt->journalid,
                              jtalkid   => $cmt->jtalkid,
                              );
}

sub event_type { 'delete_comment' }

1;
