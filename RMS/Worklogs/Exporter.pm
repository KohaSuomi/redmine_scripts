package RMS::Worklogs::Exporter;

## Omnipresent pragma setter
use 5.18.2;
use utf8;
use Carp;
use autodie;
$Carp::Verbose = 'true'; #die with stack trace
## Pragmas set

use DateTime::Format::Duration;
use DateTime::Format::Strptime;
use ODF::lpOD;

use RMS::Dates;
use RMS::Worklogs::Day;
use RMS::Logger;
my $l = bless({}, 'RMS::Logger');

=head2 new

@PARAM1 {
          worklogDays => RMS::Worklogs->asDays(),
          file => '/tmp/workdays',                      #suffix is appended based on the exported type
          year => 2017,
        }

=cut

my $dtF_hms = DateTime::Format::Strptime->new(
    pattern   => 'PT%HH%MM%SS',
);
my $ddF_hms = DateTime::Format::Duration->new(
                    pattern => '%PPT%HH%MM%SS',
                    normalise => 'ISO',
                    base => DateTime->now(),
                );

my $defaultTime = 'PT00H00M00S' || '';

sub new {
  my ($class, $params) = @_;

  my $self = {
    worklogDays => $params->{worklogDays},
    file => $params->{file},
    baseOds => 'base4.ods',
    year => $params->{year},
  };

  bless($self, $class);
  return $self;
}

sub asOds {
  my ($self) = @_;
  my $file = $self->{file}.'.ods';
  my $days = $self->{worklogDays};
  my @dates = sort keys %{$days};

  my $rowsPerMonth = 40;

  #Load document and write metadata
  my $doc = odf_document->get( $self->{baseOds} );
  my $meta = $doc->meta;
  $meta->set_title('Työaika kivajuttu');
  $meta->set_creator('Olli-Antti Kivilahti');
  $meta->set_keywords('Koha-Suomi', 'Työajanseuranta');

  my $t = $doc->get_body->get_table_by_name('_data_');
  _checksAndVerifications($t);
  ##Make sure the _data_-sheet is big enough (but not too big)
  #We put each day in monthly chunks to the _data_-sheet with ample spacing between months.
  #So roughly 40 rows per months should do it cleanly.
  my ($neededHeight, $neededWidth) = ($rowsPerMonth*12, 22);
  my ($height, $width) = $t->get_size();
  if ($height < $neededHeight) {
    $l->debug("Base .ods '".$self->{baseOds}."' is lower '$height' than needed '$neededHeight'") if $l->is_debug();
    $t->add_row(number => $neededHeight-$height);
  }
  elsif ($height > $neededHeight) {
    $l->error("Base .ods '".$self->{baseOds}."' is higher '$height' than needed '$neededHeight'. This has performance implications.") if $l->is_error();
    $t->delete_row(-1) for 1..($height-$neededHeight);
  }
  if ($width < $neededWidth) {
    $l->debug("Base .ods '".$self->{baseOds}."' is narrower '$width' than needed '$neededWidth'") if $l->is_debug();
    $t->add_column(number => $neededWidth-$width);
  }
  elsif ($width > $neededWidth) {
    $l->error("Base .ods '".$self->{baseOds}."' is wider '$width' than needed '$neededWidth'. This has performance implications.") if $l->is_error();
    $t->delete_column(-1) for 1..($width-$neededWidth);
  }

  my ($prevY, $prevM, $prevD);
  my $rowNumber = 0;
  my $rowPointer = \$rowNumber;

  foreach my $ymd (@dates) {
    my $day = $days->{$ymd};
    my ($y, $m, $d) = $ymd =~ /^(\d\d\d\d)-(\d\d)-(\d\d)$/;
    if ($self->{year} && $y != $self->{year}) {
      $l->debug("Day '$ymd' not in year '".$self->{year}."'") if $l->is_debug();
      next;
    }
    $l->info("Exporting day '$ymd'") if $l->is_info();
    #Check if the month changes, so we reorient the pointer
    if (not($prevM) || $m ne $prevM) {
      _startMonth($t, $rowPointer, $y, $m, $d, $rowsPerMonth);
    }
    _writeDay($t, $rowPointer, $ymd, $day);

    ($prevY, $prevM, $prevD) = ($y, $m, $d);
    $$rowPointer++;
  }

  $l->info("Saving to '$file'") if $l->is_info();
  $doc->save(target => $file);
  $doc->forget();
  return $file;
}

sub _checksAndVerifications {
  my ($t) = @_;

  $l->fatal("'date' is not a known ODF datatype") unless is_odf_datatype('date');
  $l->fatal("'time' is not a known ODF datatype") unless is_odf_datatype('time');
  $l->fatal("'boolean' is not a known ODF datatype") unless is_odf_datatype('boolean');
  $l->fatal("'string' is not a known ODF datatype") unless is_odf_datatype('string');
}

sub _startMonth {
  my ($t, $rowPointer, $y, $m, $d, $rowsPerMonth) = @_;

  #Calculate from where the next month begins
  if (1) { #Calculate the correct iterator position from the month requested.
    $$rowPointer = ($m-1) * $rowsPerMonth; #cell coordinates start from 0. Months start from 1.
    $l->debug("Starting a new month '$y-$m-$d' on row '$$rowPointer'. Rows preserved for month '$rowsPerMonth'. Calculating from month number") if $l->is_debug;
  } else { #Use iterator to move to the next available month slot.
    my $rowsUsedDuringPrevMonth = $$rowPointer % $rowsPerMonth;
    my $neededToNextMonthStart = $rowsPerMonth - $rowsUsedDuringPrevMonth;
    $l->debug("Starting a new month '$y-$m-$d' on row '$$rowPointer'. Rows preserved for month '$rowsPerMonth'. Rows used during the last month '$rowsUsedDuringPrevMonth'. Skipping '$neededToNextMonthStart' rows forward to start a new month.") if $l->is_debug;
    $$rowPointer += $neededToNextMonthStart if $rowsUsedDuringPrevMonth;
  }

  my $c; my $r=0;
  #            row,       col, value, formatter
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('day');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('start');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('end');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('break');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('+/-');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('duration');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('workAccumulation');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('vacationAccumulation');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('remote?');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('benefits?');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('vacation');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('paid-leave');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('non-paid-leave');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('sick-leave');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('care-leave');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('training');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('eveningWork');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('dailyOverwork1');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('dailyOverwork2');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('saturday?');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('sunday?');
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string');$c->set_value('comments');
  $$rowPointer++;
}

sub _writeDay {
  my ($t, $rowPointer, $ymd, $day) = @_;

  my ($c, $v); my $r = 0;
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('date');   $c->set_value($ymd);
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->start ? $dtF_hms->format_datetime($day->start) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->end ? $dtF_hms->format_datetime($day->end) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->breaks ? RMS::Dates::formatDurationOdf($day->breaks) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->overwork ? RMS::Dates::formatDurationOdf($day->overwork) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->duration ? RMS::Dates::formatDurationOdf($day->duration) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  RMS::Dates::formatDurationOdf($day->overworkAccumulation)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  RMS::Dates::formatDurationOdf($day->vacationAccumulation)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  RMS::Dates::formatDurationOdf($day->remote)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('boolean');$c->set_value(  odf_boolean($day->benefits)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->vacation ? RMS::Dates::formatDurationOdf($day->vacation) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->paidLeave ? RMS::Dates::formatDurationOdf($day->paidLeave) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->nonPaidLeave ? RMS::Dates::formatDurationOdf($day->nonPaidLeave) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->sickLeave ? RMS::Dates::formatDurationOdf($day->sickLeave) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->careLeave ? RMS::Dates::formatDurationOdf($day->careLeave) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->learning ? RMS::Dates::formatDurationOdf($day->learning) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->eveningWork ? RMS::Dates::formatDurationOdf($day->eveningWork) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->dailyOverwork1 ? RMS::Dates::formatDurationOdf($day->dailyOverwork1) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('time');   $c->set_value(  $day->dailyOverwork2 ? RMS::Dates::formatDurationOdf($day->dailyOverwork2) : $defaultTime  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('boolean');$c->set_value(  odf_boolean($day ? $day->isSaturday : undef)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('boolean');$c->set_value(  odf_boolean($day ? $day->isSunday : undef)  );
  $c = $t->get_cell($$rowPointer, $r++ );$c->set_type('string'); $c->set_value(  $day->comments  );

  $l->debug("$$rowPointer: $ymd - ".($day ? $day : 'undef')) if $l->is_debug();
}


sub asCsv {
  my ($self) = @_;
  my $file = $self->{file}.'.csv';

  my $csv = Text::CSV->new or die "Cannot use CSV: ".Text::CSV->error_diag ();
  $csv->eol("\n");
  $l->info("Writing to '$file'") if $l->is_info();
  open my $fh, ">:encoding(utf8)", $file or die "$file: $!";

  my $days = $self->{worklogDays};
  my @dates = sort keys %{$days};
  my $dates = $self->fillMissingYMDs(\@dates);

  foreach my $ymd (@$dates) {
    my $day = $days->{$ymd};
    my $row;
    if ($day) {
      $row = [
        $ymd,
        $day->start->hms,
        $day->end->hms,
        RMS::Dates::formatDurationPHMS($day->breaks),
        RMS::Dates::formatDurationPHMS($day->duration),
        RMS::Dates::formatDurationPHMS($day->overwork),
      ];
    }
    else {
      $days->{$ymd} = undef;
      $row = [
        $ymd,
        undef, undef, undef, undef, undef,
      ];
    }
    $csv->print($fh, $row);
  }

  close $fh or die "$file: $!";
  return $days;
}

=head2 $class->fillMissingYMDs

Given a list of YMDs, fill any missing YMD to make a continuous list of YMDs wihtout missing days.

@PARAM1 $class,
@PARAM2 Arrayref of String, YMDs
@RETURNS Arrayref of String, YMDs with missing days filled

=cut

sub fillMissingYMDs {
    my ($class, $ymds) = @_;

    my @ymds;
    for (my $i=0 ; $i<scalar(@$ymds) ; $i++) {
        my $a = DateTime::Format::MySQL->parse_datetime( $ymds->[$i].' 00:00:00' );
        my $b = DateTime::Format::MySQL->parse_datetime( $ymds->[$i+1].' 00:00:00' ) if $ymds->[$i+1];

        do {
            push(@ymds, $a->ymd());
            $a->add_duration( DateTime::Duration->new(days => 1) );
        } while ($b && $a < $b);
    }
    return \@ymds;
}

1;
