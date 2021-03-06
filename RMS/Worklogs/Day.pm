package RMS::Worklogs::Day;

use 5.18.2;
use Carp;
use Params::Validate qw(:all);

use DateTime::Duration;

use RMS::Dates;
use RMS::Worklogs::Tags;
use RMS::WorkRules;

use RMS::Logger;
my $l = bless({}, 'RMS::Logger');


=head2 new

    RMS::Worklogs::Day->new({
      start => DateTime,                 #When the workday started
      end => DateTime,                   #When the workday ended
      breaks => DateTime::Duration,      #How long breaks have been held in total
      duration => DateTime::Duration,    #How long the workday was?
      overflow => DateTime::Duration,    #How much was the ending time forcefully delayed?
      underflow => $underflowDuration,   #How much was the starting time forcefully earlied?
      benefits => 1 || undef,            #Should we calculate extra work bonuses for this day?
      remote => 1 || undef,              #Was this day a remote working day?
      comments => "Freetext",            #All the worklog comments for the day
    });

=cut

our %validations = (
    start    =>   {isa => 'DateTime'},
    end      =>   {isa => 'DateTime'},
    breaks   =>   {isa => 'DateTime::Duration'},
    duration =>   {isa => 'DateTime::Duration'},
    specialDurations => {type => HASHREF, optional => 1},
    benefits =>   {type => SCALAR|UNDEF},
    remote   =>   {callbacks => { isa_undef => sub {    not(defined($_[0])) || $_[0]->isa('DateTime::Duration')    }}, optional => 1},
    overwork =>   {callbacks => { isa_undef => sub {    not(defined($_[0])) || $_[0]->isa('DateTime::Duration')    }}, optional => 1},
    overworkReimbursed =>   {callbacks => { isa_undef => sub {    not(defined($_[0])) || $_[0]->isa('DateTime::Duration')    }}, optional => 1},
    overworkReimbursedBy => {type => SCALAR|UNDEF, depends => 'overworkReimbursed'},
    overworkAccumulation => {isa => 'DateTime::Duration'},
    vacationAccumulation => {isa => 'DateTime::Duration'},
    overflow  =>  {callbacks => { isa_undef => sub {    not(defined($_[0])) || $_[0]->isa('DateTime::Duration')    }}, optional => 1},
    underflow =>  {callbacks => { isa_undef => sub {    not(defined($_[0])) || $_[0]->isa('DateTime::Duration')    }}, optional => 1},
    comments  =>  {type => SCALAR|UNDEF},
    userId    =>  {type => SCALAR},
);
sub new {
    my ($class) = shift;
    my $params = validate(@_, \%validations);

    #If the end time overflows because workday duration is too long, append a warning to comments
    #eg. "!END overflow 00:33:12!A typical comment."
    $params->{comments} = '!END overflow '.RMS::Dates::formatDurationHMS($params->{overflow}).'!'.($params->{comments} ? $params->{comments} : '') if ($params->{overflow});
    $params->{comments} = '!START underflow '.RMS::Dates::formatDurationHMS($params->{underflow}).'!'.($params->{comments} ? $params->{comments} : '') if ($params->{underflow});

    my $self = {
        ymd =>       $params->{start}->ymd(),
        start =>     $params->{start},
        end =>       $params->{end},
        breaks =>    $params->{breaks},
        duration =>  $params->{duration},
        benefits =>  $params->{benefits},
        remote =>    $params->{remote},
        overworkReimbursed => $params->{overworkReimbursed},
        overworkReimbursedBy => $params->{overworkReimbursedBy},
        overflow =>  $params->{overflow},
        underflow => $params->{underflow},
        comments =>  $params->{comments},
        userId =>    $params->{userId},
    };
    #Special work types/durations
    if ($params->{specialDurations}) {
        foreach my $key (%{$params->{specialDurations}}) {
            $self->{$key} = $params->{specialDurations}->{$key};
        }
    }
    bless($self, $class);

    $self->setOverwork();
    $self->setOverworkAccumulation($params->{overworkAccumulation});
    $self->setDailyOverworks();
    $self->setEveningWork();
    $self->setVacationAccumulation($params->{vacationAccumulation});
    return $self;
}

=head2 newFromWorklogs

Given a bunch of worklogs for a single day, from the Redmine DB,
a flattened day-representation of the events happened within those worklog entries is returned.

@PARAM1 $class
@PARAM2 String, YYYY-MM-DD of the day being created
@PARAM3 DateTime::Duration, How much overwork has been accumulated up to this day. Exclusive of this day.
@PARAM4 DateTime::Duration, How much vacation has been accumulated up to this day. Exclusive of this day.
@PARAM5 ARRAYref  of redmine.time_entry-rows for the given day.

=cut

sub newFromWorklogs {
    my ($class, $dayYMD, $overworkAccumulation, $vacationAccumulation, $worklogs) = @_;
    unless ($dayYMD =~ /^\d\d\d\d-\d\d-\d\d$/) {
        confess "\$day '$dayYMD' is not a proper YYYY-MM-DD date";
    }

    my ($startDt, $endDt, $breaksDuration, $workdayDuration, $benefits, $remote, $overflowDuration, $underflowDuration, $overworkReimbursed, $overworkReimbursedBy);
    my @wls = sort {$a->{created_on} cmp $b->{created_on}} @$worklogs; #Sort from morning to evening, so first index is the earliest log entry

    ##Flatten all comments so tags can be looked for
    my @comments;
    ##Sum the durations of all individual worklog entries, vacations, paidLeave, sickLeave, careLeave, learning
    my %specialDurations;
    $workdayDuration = DateTime::Duration->new();
    foreach my $wl (@wls) {
        my $timeEntryDuration = RMS::Dates::hoursToDuration( $wl->{hours} );
        $workdayDuration = $workdayDuration->add_duration($timeEntryDuration);
        $l->trace("$dayYMD -> Duration grows to ".RMS::Dates::formatDurationHMS($workdayDuration)) if $l->is_trace();

        my $specialIssue = RMS::WorkRules::getSpecialWorkCategory($wl->{issue_id}, $wl->{activity});
        if ($specialIssue) {
            $specialDurations{$specialIssue} = ($specialDurations{$specialIssue}) ? $specialDurations{$specialIssue}->add_duration(RMS::Dates::hoursToDuration( $wl->{hours} )) : RMS::Dates::hoursToDuration( $wl->{hours} );
            $l->trace("$dayYMD -> Special work category '$specialIssue' grows to ".RMS::Dates::formatDurationHMS($specialDurations{$specialIssue})) if $l->is_trace();
        }

        if ($wl->{comments}) {
            my ($_benefits, $_remote, $_startDt, $_endDt, $_overworkReimbursed, $_overworkReimbursedBy, $_comments) = RMS::Worklogs::Tags::parseTags($wl->{comments});
            push(@comments, $_comments || $wl->{comments});
            $l->trace("$dayYMD -> Comment prepended '".$wl->{comments}."'") if $wl->{comments} && $l->is_trace();

            ##{{REMOTE}} tag was found. We increment the remote working duration for this day
            if ($_remote) {
                if ($remote) {
                    $remote->add_duration($timeEntryDuration);
                }
                else {
                    $remote = $timeEntryDuration;
                }
            }
            $benefits = $_benefits unless $benefits;
            $startDt = $_startDt unless $startDt;
            $endDt = $_endDt unless $endDt;
            $overworkReimbursed = $_overworkReimbursed unless $overworkReimbursed;
            $overworkReimbursedBy = $_overworkReimbursedBy unless $overworkReimbursedBy;
        }
    }


    #Hope to find some meaningful start time
    if (not($startDt)) {
        $startDt = $class->guessStartTime($dayYMD, \@wls);
    }

    #Hope to find some meaningful end time from the last worklog
    if (not($endDt) && $wls[-1]->{created_on} =~ /^$dayYMD/) {
        $endDt = DateTime::Format::MySQL->parse_datetime( $wls[-1]->{created_on} );
        $l->trace("$dayYMD -> End ".$endDt->hms()) if $l->is_trace();
    }


    ($startDt, $underflowDuration) = $class->_verifyStartTime($dayYMD, $startDt, $workdayDuration);
    ($endDt, $overflowDuration) = $class->_verifyEndTime($dayYMD, $startDt, $endDt, $workdayDuration);
    $breaksDuration = $class->_verifyBreaks($dayYMD, $startDt, $endDt, $workdayDuration);

    return RMS::Worklogs::Day->new({
        start => $startDt, end => $endDt, breaks => $breaksDuration, duration => $workdayDuration,
        overflow => $overflowDuration, underflow => $underflowDuration, benefits => $benefits,
        remote => $remote, comments => join(' ', @comments), specialDurations => \%specialDurations,
        overworkReimbursed => $overworkReimbursed, overworkReimbursedBy => $overworkReimbursedBy,
        overworkAccumulation => $overworkAccumulation, vacationAccumulation => $vacationAccumulation,
        userId => $wls[0]->{user_id},
    });
}

sub ymd {
    return shift->{ymd};
}
sub day {
    return shift->start->ymd('-');
}
sub start {
    return shift->{start};
}
sub end {
    return shift->{end};
}
sub duration {
    return shift->{duration};
}
sub breaks {
    return shift->{breaks};
}
sub setOverwork {
    my ($self) = @_;
    my $dayLength = RMS::WorkRules::getDayLengthDd($self->start);
    $self->{overwork} = $self->duration->clone->subtract($dayLength);
    return $self;
}
sub overwork {
    return shift->{overwork};
}
sub setOverworkAccumulation {
    my ($self, $overworkAccumulation) = @_;
    $overworkAccumulation = $overworkAccumulation->clone()->add_duration($self->overwork);
    $overworkAccumulation->subtract_duration($self->overworkReimbursed) if $self->overworkReimbursed;
    $self->{overworkAccumulation} = $overworkAccumulation;
    $l->trace("\$overworkAccumulation='".RMS::Dates::formatDurationPHMS($overworkAccumulation)."'") if $l->is_trace();
}
sub overworkAccumulation {
    return shift->{overworkAccumulation};
}
sub overworkReimbursed {
    return shift->{overworkReimbursed};
}
sub overworkReimbursedBy {
    return shift->{overworkReimbursedBy};
}
sub setVacationAccumulation {
    my ($self, $vacationAccumulation) = @_;
    $vacationAccumulation = $vacationAccumulation->clone();
    $l->trace("\$vacationAccumulation=".RMS::Dates::formatDurationPHMS($vacationAccumulation)) if $l->is_trace();
    #If today is the day when new vacations become available, add those vacations to the vacations quota
    if ($self->start->day == RMS::WorkRules::getVacationAccumulationDayOfMonth()) {

        my $newVacations = RMS::WorkRules::getVacationAccumulationDuration($self->userId, $self->start);
        $vacationAccumulation->add_duration(  $newVacations  );
        $l->trace("New vacations earned '".RMS::Dates::formatDurationPHMS($newVacations)."', \$vacationAccumulation=".RMS::Dates::formatDurationPHMS($vacationAccumulation)) if $l->is_trace();
    }
    #Check if vacations are used
    if ($self->vacation) {
        $vacationAccumulation->subtract_duration($self->vacation);
        $l->trace("Vacations used '".RMS::Dates::formatDurationPHMS($self->vacation)."', \$vacationAccumulation=".RMS::Dates::formatDurationPHMS($vacationAccumulation)) if $l->is_trace();
    }
    #Store the vacation quota
    $self->{vacationAccumulation} = $vacationAccumulation;
}
sub vacationAccumulation {
    return shift->{vacationAccumulation};
}
sub overflow {
    return shift->{overflow};
}
sub underflow {
    return shift->{underflow};
}
sub remote {
    return shift->{remote};
}
sub benefits {
    return shift->{benefits};
}
sub comments {
    return shift->{comments};
}
sub setDailyOverworks {
    my ($self) = @_;
    if (DateTime::Duration->compare($self->overwork, RMS::Dates::zeroDuration()) <= 0) { #If we have negative overwork. Haven't completed all daily hours
        $self->{dailyOverwork1} = RMS::Dates::zeroDuration();
        $self->{dailyOverwork2} = RMS::Dates::zeroDuration();
        return $self;
    }
    if (DateTime::Duration->compare($self->overwork, RMS::WorkRules::getDailyOverworkThreshold1()) <= 0) {
        $self->{dailyOverwork1} = $self->overwork; #overwork is less than the first threshold
    }
    else {
        $self->{dailyOverwork2} = $self->overwork->clone()->subtract_duration( RMS::WorkRules::getDailyOverworkThreshold1() );
        $self->{dailyOverwork1} = RMS::WorkRules::getDailyOverworkThreshold1()->clone();
    }
    return $self;
}
sub dailyOverwork1 {
    return shift->{dailyOverwork1};
}
sub dailyOverwork2 {
    return shift->{dailyOverwork2};
}
sub setEveningWork {
    my $end = $_[0]->end;
    my $endDur = DateTime::Duration->new(hours => $end->hour, minutes => $end->minute, seconds => $end->second);
    $endDur->subtract_duration(RMS::WorkRules::getEveningWorkThreshold);
    if (DateTime::Duration->compare($endDur, RMS::Dates::zeroDuration) > 0) { #Our day ends after the evening threshold
        $_[0]->{eveningWork} = $endDur;
    }
    return $_[0];
}
sub eveningWork {
    return shift->{eveningWork};
}
sub isSaturday {
    unless ($_[0]->start) {
        my $dt = RMS::Dates::dateTimeFromYMD($_[0]->ymd);
        $_[0]->{isSaturday} = ($dt->day_of_week == 6);
        return $_[0]->{isSaturday};
    }
    return $_[0]->{isSaturday} if (not($_[0]->start));
    return 1 if ($_[0]->start->day_of_week == 6);
}
sub isSunday {
    unless ($_[0]->start) {
        my $dt = RMS::Dates::dateTimeFromYMD($_[0]->ymd);
        $_[0]->{isSunday} = ($dt->day_of_week == 7);
        return $_[0]->{isSunday};
    }
    return $_[0]->{isSunday} if (not($_[0]->start));
    return 1 if $_[0]->start->day_of_week == 7;
}
sub userId {
    return shift->{userId};
}
#Special work type accessors
sub vacation {
    return shift->{vacation};
}
sub paidLeave {
    return shift->{paidLeave};
}
sub nonPaidLeave {
    return shift->{nonPaidLeave};
}
sub careLeave {
    return shift->{careLeave};
}
sub sickLeave {
    return shift->{sickLeave};
}
sub learning {
    return shift->{learning};
}

=head2 guessStartTime

Looks for the earliest time_entries which have been created in a rapid succession.
Presumably these constitute as the starting time of the day.
Eg. one can log all the work done during the day when leaving office, spread over multiple issues,
then the first created_by-timestamp only tells when the first time_entry has been created.
Actually we need to go back in time the combined duration of time_entries logged when leaving office,
instead of the duration of the first time_entry.

If there are no time_entries in close succession, takes the earliest created_by-time.

@PARAM1 ARRAYRef of redmine.time_entry HASHRefs sorted by created_on-datetime from earliest to latest
@RETURNS DateTime, start time of the day

=cut

my $timeEntryLoggingSuccessionDelay = DateTime::Duration->new(minutes => 10); #How closely together time_entries need to be logged, to be considered a single work-event?
sub guessStartTime {
    my ($class, $dayYMD, $wls) = @_;

    my @startingWorkEvent;
    for (my $i=0 ; $i<scalar(@$wls) ; $i++) {
        next unless ($wls->[$i]->{created_on} =~ /^$dayYMD/); #Skip time_entries not from the given day
        push(@startingWorkEvent, $wls->[$i]) if (not(scalar(@startingWorkEvent))); #The first work event always has atleast the first valid time_entry
        last unless $wls->[$i+1];
        my $dt0 = DateTime::Format::MySQL->parse_datetime( $wls->[$i]->{created_on} );
        my $dt1 = DateTime::Format::MySQL->parse_datetime( $wls->[$i+1]->{created_on} );
        my $differenceDd = $dt1->subtract_datetime($dt0); #Because $dt0 is always < $dt1, $differenceDd is always positive

        if (DateTime::Duration->compare($differenceDd, $timeEntryLoggingSuccessionDelay) <= 0) { #If difference is less than equal to the given threshold, we consider these time_entries as one workEvent
            push(@startingWorkEvent, $wls->[$i+1]);
            $l->trace("$dayYMD -> Found start time followup ymd='".$dt0->ymd()." -> ".$dt1->ymd()."', hours='".$wls->[$i]->{hours}." -> ".$wls->[$i+1]->{hours}."'") if $l->is_trace();
        }
        else {
            last; #No point in iterating if there has been too big a gap between logging time_entries
        }
    }

    return undef unless (scalar(@startingWorkEvent));
    #Calculate the combined duration of the starting work event
    my $combinedDuration = DateTime::Duration->new();
    $combinedDuration->add_duration( RMS::Dates::hoursToDuration( $_->{hours} ) ) for @startingWorkEvent;

    my $firstTimeEntryCreatedDt = DateTime::Format::MySQL->parse_datetime( $startingWorkEvent[0]->{created_on} );
    my $startDt = $firstTimeEntryCreatedDt->clone->subtract_duration($combinedDuration);
    $l->debug("$dayYMD -> start='".$firstTimeEntryCreatedDt->hms()." -> ".$startDt->hms()."', duration='".RMS::Dates::formatDurationHMS($combinedDuration)."'") if $l->is_debug();
    return $startDt;
}

=head2 $class->_verifyStartTime

Start time defaults to 08:00, or the one given, but we must check if the workday
duration actually can fit inside one day if it starts at 08:00

We might have to shift the start time earlier than 08:00 in some cases where
days have been very long.

It is possible for the $startDt to be earlier than the current day, so we must
adjust that back to 00:00:00. This can happen when one logs more hours than there
have been up to the moment of logging
If such an underflow event occurs, the underflow duration is returned

@RETURNS (DateTime, $underflowDuration);

=cut

sub _verifyStartTime {
    my ($class, $dayYMD, $startDt, $duration) = @_;

    unless ($startDt) {
        $startDt = DateTime::Format::MySQL->parse_datetime( "$dayYMD 08:00:00" );
        $l->trace("$dayYMD -> Spoofing \$startDt") if $l->is_trace();
    }
    if ($startDt->isa('DateTime::Duration')) {
        $startDt = DateTime::Format::MySQL->parse_datetime( "$dayYMD ".RMS::Dates::formatDurationHMS($startDt) );
    }
    unless ($startDt->ymd('-') eq $dayYMD) { #$startDt might get moved to the previous day, so catch this and fix it.
        $l->trace("$dayYMD -> Moving \$startDt to $dayYMD from ".$startDt->ymd()) if $l->is_trace();
        $startDt = DateTime::Format::MySQL->parse_datetime( "$dayYMD 00:00:01" ); #one second is important to distinguish this value from undefined to defined, and affects how this value is displayed in LibreOffice
    }

    ##Calculate how many hours is left for today after work
    my $remainder = DateTime::Duration->new(days => 1)->subtract( $duration );

    my $startDuration = $startDt->subtract_datetime(  DateTime::Format::MySQL->parse_datetime( "$dayYMD 00:00:00" )  ); #We get the hours and minutes
    if (DateTime::Duration->compare($remainder, $startDuration, $startDt) >= 0) { #Remainder is bigger than the starting hours, so we have plenty of time today to fill the worktime starting from the given startTime
        return ($startDt, undef);
    }
    #If we started working on the starting time, and we cannot fit the whole workday duration to the current day. So we adjust the starting time to an earlier time.
    $startDuration->subtract($remainder);
    $l->trace("$dayYMD -> Rewinding \$startDt to fit the whole workday ".RMS::Dates::formatDurationHMS($duration)." from ".$startDt->hms().' by '.RMS::Dates::formatDurationHMS($startDuration)) if $l->is_trace();
    $startDt->subtract_duration($startDuration);
    $startDt->subtract_duration(DateTime::Duration->new(seconds => 1)); #remove one minute from midnight so $endDt is not 00:00:00 but 23:59:59 instead
    return ($startDt, $startDuration);
}

=head2 $class->_verifyEndTime

End time defaults to $startTime + workday duration, or the one given
If the given workday duration cannot fit between the given start time and the given end time,
  a comment !END overflow HH:MM:SS! is appended to the workday comments.
@RETURNS (DateTime, $overflowDuration);

=cut

sub _verifyEndTime {
    my ($class, $dayYMD, $startDt, $endDt, $duration) = @_;

    #Create default end time from start + duration
    unless ($endDt) {
        $endDt = $startDt->clone()->add_duration($duration);
        $l->trace("$dayYMD -> Spoofing \$endDt") if $l->is_trace();
    }
    if ($endDt->isa('DateTime::Duration')) {
        $endDt = DateTime::Format::MySQL->parse_datetime( "$dayYMD ".RMS::Dates::formatDurationHMS($endDt) );
    }

    #Check if workday duration fits between start and end.
    if (DateTime->compare($startDt->clone()->add_duration($duration), $endDt) <= 0) {
        return ($endDt, undef);
    }

    #it didn't fit, push end time forward. _verifyStartTime() should make sure this doesn't push the ending date to the next day.
    my $overflowDuration = $startDt->clone()->add_duration($duration)->subtract_datetime($endDt);
    $l->trace("$dayYMD -> Overflowing \$endDt from ".$endDt->hms().' by '.RMS::Dates::formatDurationHMS($overflowDuration)) if $l->is_trace();
    return ($startDt->clone()->add_duration($duration),
            $overflowDuration);
}

sub _verifyBreaks {
    my ($class, $dayYMD, $startDt, $endDt, $duration) = @_;

    my $realDuration = $endDt->subtract_datetime($startDt);
    $realDuration->subtract($duration);
    return $realDuration if (DateTime::Duration->compare($realDuration, DateTime::Duration->new(), $startDt) >= 0); #$realDuration is positive.

    #Break is negative, so $startDt and $endDt are too tight for $duration
    #If duration is -00:00:01 (-1 second) we let it slip, but only this time!
    return $realDuration if (DateTime::Duration->compare($realDuration, DateTime::Duration->new(seconds => -1), $startDt) >= 0); #$realDuration is bigger than -1 seconds.

    confess "\$startDt '".$startDt->iso8601()."' and \$endDt '".$endDt->iso8601()."' is too tight to fit the workday duration '".RMS::Dates::formatDurationPHMS($duration)."'. Break '".RMS::Dates::formatDurationPHMS($realDuration)."' cannot be negative!\n";
}

1;
