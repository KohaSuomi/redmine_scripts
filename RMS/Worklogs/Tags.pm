package RMS::Worklogs::Tags;

use Modern::Perl;
use Carp;
use utf8;

use DateTime::Duration;

use RMS::Dates;

use RMS::Logger;
my $l = bless({}, 'RMS::Logger');

=head2 parseTags

Extracts tags from the given comments and returns the extracted tags casted to
their representative objects and what remains of the comment after the tags
have been extracted.

@RETURNS List of stuff, ($benefits, $remote, $start, $end, $overworkReimbursed, $overworkReimbursedBy, $comments)

=cut

#Precompile regexps for speed
my $tagExtractorRegexp = qr/\{\{(.+?)\}\}/;
my $startExtractorRegexp = qr/^(?:START|BEGIN|ALKU) ?(\d\d)\D?(\d\d)/;
my $endExtractorRegexp = qr/^(?:END|CLOSE|LOPPU) ?(\d\d)\D?(\d\d)/;
my $overworkReimbursedExtractorRegexp = qr/^(?:REIMBURSED|PAID|MAKSETTU) ?([-+]?)(\d{1,3})\D?(\d\d) ?(.+)/;
sub parseTags {
    my ($comments) = @_;

=bug Backreferencing Named capture groups doesnt work when substituting with nothing, and even then.
    if ($comments =~ s/
            \{\{(                                         #tags start with {{
                (?<BENEFITS>BENEFITS|BONUS)      |       #Catch BENEFITS and it's aliases
                (?<REMOTE>REMOTE|ETÄ)            |       #Catch REMOTE and it's aliases
                (?<START>(?:START|BEGIN|ALKU)\d{4})|       #Catch START and it's aliases
                (?<END>(?:END|CLOSE|LOPPU)\d{4})           #Catch END and it's aliases
            )\}\}                                         #tags end with }}
        //xug) {
=cut
    if (my @c = $comments =~ /$tagExtractorRegexp/g) {
        my ($benefits, $remote, $start, $end, $overworkReimbursed, $overworkReimbursedBy);
        $comments =~ s/$tagExtractorRegexp//g;

        foreach my $c (@c) {
            if ($c eq 'BENEFITS' || $c eq 'BONUS') {
                $benefits = 1;
            } elsif ($c eq 'REMOTE' || $c eq 'ETÄ') {
                $remote   = 1;
            } elsif ($c =~ /$startExtractorRegexp/) {
                $start    = DateTime::Duration->new(hours => $1, minutes => $2);
            } elsif ($c =~ /$endExtractorRegexp/) {
                $end      = DateTime::Duration->new(hours => $1, minutes => $2);
            } elsif ($c =~ /$overworkReimbursedExtractorRegexp/) {
                my $sign = $1; #positive or negative
                $overworkReimbursed = DateTime::Duration->new(hours => $2, minutes => $3);
                $overworkReimbursed = $overworkReimbursed->inverse() if $sign eq '-';
                $overworkReimbursedBy = $4;
                $comments = "$c. $comments";
            } else {
                $comments = "Strange tag {{$c}}? $comments";
            }
        }
        if ($l->is_debug()) {
            $l->debug('Returns with: '.
                      ($benefits ? "\$benefits=$benefits, " : '').
                      ($remote ?   "\$remote=$remote, " : '').
                      ($start ?    "\$start=".RMS::Dates::formatDurationHMS($start).', ' : '').
                      ($end ?      "\$end=".RMS::Dates::formatDurationHMS($end).', ' : '').
                      ($comments ? "\$comments=$comments" : '').
                      ($overworkReimbursed ? "\$overworkReimbursed=".RMS::Dates::formatDurationPHMS($overworkReimbursed).' '.$overworkReimbursedBy.', ' : '').
            '');
        }
        return ($benefits, $remote, $start, $end, $overworkReimbursed, $overworkReimbursedBy, $comments);
    }
    $l->debug("Returns with:") if $l->is_debug();
    return undef; #Explicitly return undef, or the return value is 0
}

1;
