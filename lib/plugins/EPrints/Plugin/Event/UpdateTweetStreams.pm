package EPrints::Plugin::Event::UpdateTweetStreams;

use EPrints::Plugin::Event::LockingEvent;
@ISA = qw( EPrints::Plugin::Event::LockingEvent );

use strict;

use URI;
use LWP::UserAgent;
use JSON;
use Encode qw(encode);
use Net::Twitter::Lite::WithAPIv1_1;

my $HTTP_RETRIES = 5; #for network errors
my $QUERY_RETRIES = 5; #for API errors
my $QUERIES_BEFORE_RATE_CHECK = 100; #because one query may use more than one of the quota if it's complex

sub action_update_tweetstreams
{
	my ($self, $verbose) = @_;

	$self->{verbose} = 1 if $verbose;

	if ($self->is_locked)
	{
		$self->repository->log( (ref $self) . " is locked.  Unable to run.");
		return;
	}
	$self->create_lock;

	$self->{log_data}->{start_time} = scalar localtime time;

	my $nt = $self->connect_to_twitter;
	if (!$nt)
	{
		$self->repository->log( (ref $self) . " was unable to connect to twitter.");
		return;
	}

	$self->output_status('Connected to Twitter');

	my $limit = get_search_rate_limit($nt); 

	$self->output_status("Initial Rate Limit: $limit");

	my $active_tweetstreams = $self->active_tweetstreams;
	my $queue_items = {};
	$active_tweetstreams->map( \&EPrints::Plugin::Event::UpdateTweetStreams::create_queue_item, $queue_items);
	my @queue = values %{$queue_items};

	$self->output_status('Queue has ' . scalar @queue . ' items');

	QUERYSET: while ($limit > 0)
	{
		my $n = $QUERIES_BEFORE_RATE_CHECK;
		$n = $limit if $limit < $n;
		QUERY: for (1..$n)
		{
			if (scalar @queue ==0)
			{
				$self->output_status('Update queue emptied');
				$self->{log_data}->{end_state} = 'Update queue emptied';
				last QUERYSET;
			}

			my $current_item = shift @queue;
			my $results = undef;
			my $results_flag = 0;
			my $err = undef;
			my $end_state = undef;

			RETRY: foreach my $retry (1..$HTTP_RETRIES)
			{
				$self->output_status('Attempting to query: ' . $current_item->{search_params}->{q});
				if (!$nt->authorized)
				{
					$self->output_status('Oops, not authorise.  Reconnecting....');
					sleep 10;
					$nt = $self->connect_to_twitter;
					next RETRY; #try again
				}

				eval {
					$results = $nt->search($current_item->{search_params});
				};

				#if we have an error, sleep and then try again, otherwise exit the retry loop.
				#note that this approach only records the final error -- oh well.
				if ( $err = $@ ) {
					#handle response codes -- see https://dev.twitter.com/docs/error-codes-responses
					if (ref $err and $err->isa('Net::Twitter::Error'))
					{
						if ($err->code == 403) #no more data for this stream -- we've gone back as far as we can
						{
							$self->output_status('Err 403: No more results for this search');
							$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state} = 'No More Results (403, went back as far as possible)';
							last RETRY;
						}
						elsif ($err->code == 429) #rate limit reached -- stop all requests
						{
							$self->output_status('ERR 429: API limit exceeded');
							$limit = -1; #we've gone over the limit
							last RETRY;
						}
					}

					output_status('Uncategorised error, retrying...');
					sleep 10;
					next RETRY;
				}
				else
				{
					$self->output_status('Results successfully retrieved');
					$results_flag = 1;
					last RETRY; #we have our results
				}
			}

			#process results and put the current item at the end of the queue (if appropriate)
			if ($results_flag)
			{
				my $results_count = scalar @{$results->{statuses}};
				#no errors, process the results
				if ($results_count < 1)#if an empty page of results, assume no more tweets
				{
					$self->output_status('Empty Results Set');
					$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state} = 'Update Completed (Hooray)';
				}
				else
				{
					$self->output_status('Retrieved ', scalar @{$results->{statuses}}, ' statuses');
					$self->process_results($current_item, $results);

					$self->output_status('Tweets created');

					#if less than a page of data, assume we've reached the end of the results
					if ($results_count < $current_item->{search_params}->{count})
					{
						$self->output_status('Less than ' . $current_item->{search_params}->{count} . ' results -- not requeueing');
						$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state} = 'Update Completed (Hooray)';
					}
					else
					{ 
						$self->output_status('Full results set -- requeueing');
						#requeue the current item

						###############
						#REQUEUE ITEM##
						###############
						push @queue, $current_item;
					}
				}
			}
			else
			{
				#we tried N times, and failed -- do not re-queue the current item
				if (ref($err) and $err->isa('Net::Twitter::Error'))
				{

					$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state} =
						"BAD RESPONSE FROM TWITTER:\n" .
						"\tHTTP Response Code: " . $err->code . "\n" .
						"\tHTTP Message......: " . $err->message . "\n" .
						"\tTwitter error.....: " . $err->error . "\n";
				}
				else
				{
					$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state} = 'Unexpected Error: ' . $@;
					#do not re-queue the current item
				}
				$self->output_status($self->{log_data}->{tweetstreams}->{$current_item->{id}}->{end_state});
			}

		}
		#update the limit, just in case.
		$limit = get_search_rate_limit($nt);
		$self->output_status("Updated limit.  It's now $limit");
	}

	$self->output_status("Updating ended");
	$self->{log_data}->{end_time} = scalar localtime time;
	$self->{log_data}->{api_rate_limit} = $limit;
	$self->write_log;
	$self->remove_lock;
}

sub process_results
{
	my ($self, $current_item, $results) = @_;

	my $repo = $self->repository;
	my $tweetstream_ds = $repo->dataset('tweetstream');

	my $tweet_dataobjs = [];

	#create a tweet dataobj for each tweet and store the objid in the queue item
	TWEET_IN_UPDATE: foreach my $tweet (@{$results->{statuses}})
	{
		$self->{log_data}->{tweets_processed}++; #global count
		$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{earliest_seen} = $tweet->{created_at}; #keep updating this as we walk backwards, though it

		#only need to set these once
		if (!$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{latest_seen})
		{
			$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{latest_seen} = $tweet->{created_at};
			$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{search_string} = $current_item->{search_params}->{q};
		}

		#keep track of the lowest twitterid we've seen for paging
		if (
			!$current_item->{search_params}->{max_id}
			|| $tweet->{id} < $current_item->{search_params}->{max_id}
		)
		{
			$current_item->{search_params}->{max_id} = $tweet->{id};
		}

		#check to see if we already have a tweet with this twitter id in this repository
		my $tweetobj = EPrints::DataObj::Tweet::tweet_with_twitterid($repo, $tweet->{id});
		if (!defined $tweetobj)
		{
			$self->output_status('Creating Tweet Object');
			$tweetobj = EPrints::DataObj::Tweet->create_from_data(
				$self->repository,
				{
					twitterid => $tweet->{id},
					json_source => $tweet,
					tweetstreams => $current_item->{tweetstreamids},
				} 
			);
			$tweetobj->commit; #will enrich the tweet

			$self->{log_data}->{tweets_created}++; #global_count
			$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{tweets_created}++;
		}
		else
		{
			$self->{log_data}->{tweetstreams}->{$current_item->{id}}->{tweets_added}++;
			$self->output_status('Tweet Object Exists');
		}

		#safe to do because we're updating in pages of 100 -- we won't run out of memory
		push @{$tweet_dataobjs}, $tweetobj;
	}

	$self->output_status('Created all tweet objects');

	#set max_id for paging
	$current_item->{search_params}->{max_id}--; #set it to one lower to an ID we have previously seen for paging

	foreach my $tweetstreamid (@{$current_item->{tweetstreamids}})
	{
		my $tweetstream = $tweetstream_ds->dataobj($tweetstreamid);
		die ("UNEXPECTED CRITICAL ERROR: couldn't create tweetstream $tweetstreamid") unless $tweetstream;

		$tweetstream->add_tweets($tweet_dataobjs);
	}
}

sub connect_to_twitter
{
	my ($self) = @_;

	my %nt_args = ( traits => [qw/API::RESTv1_1/] );
	foreach (qw( consumer_key consumer_secret access_token access_token_secret ))
	{
		$nt_args{$_} = $self->repository->config('twitter_oauth',$_);
	}

	my $nt = Net::Twitter::Lite::WithAPIv1_1->new( %nt_args );

#handle this error properly;
	if (!$nt->authorized)
	{
		$self->repository->log( (ref $self) . " Net::Twitter Oauth issue\n");
		return undef;
	}
	return $nt;
}


#return a value or an empty string
sub v
{
	my ($val, $default) = @_;
	return $val if defined $val;
	return $default if defined $default;
	return '';
}

sub generate_log_string
{
	my ($self) = @_;
	my $l = $self->{log_data};

	my @r;

	push @r, "Update started at: " . v($l->{start_time});
	push @r, "Update finished at: " . v($l->{end_time});
	push @r, "API Queries left: " . v($l->{api_rate_limit});
	push @r, v($l->{tweets_processed}, 0) . " tweets processed";
	push @r, v($l->{tweets_created}, 0) . " tweets created";
	push @r, (scalar keys %{$l->{tweetstreams}}, 0) . " tweetstreams updated:";

	foreach my $ts_id (sort keys %{$l->{tweetstreams}})
	{
		my $ts = $l->{tweetstreams}->{$ts_id};

		my $new = v($ts->{tweets_created},0);
		my $added = v($ts->{tweets_added},0);
		my $end = v($ts->{end_state},'Unknown Endstate');
		my $earliest = v($ts->{earliest_seen},'unknown');
		my $latest = v($ts->{latest_seen},'unknown');

		push @r, "\t$ts_id: " . v($ts->{search_string},'undef') ;
		push @r, "\t\t$new created";
		push @r, "\t\t$added existing tweets added (stream overlap or page shifting)";
		push @r, "\t\tFrom: $earliest";
		push @r, "\t\tTo:   $latest";
		push @r, "\t\tCompleted with status: $end";
	}

	my $end = v($l->{end_state},'No Known Errors');
	push @r, "Complete with status: " . $end;

	return join("\n",@r);
}

sub create_queue_item
{
	my ($repo, $ds, $tweetstream, $queue_items) = @_;

	return unless $tweetstream->is_set('search_string');
	return if (
		$tweetstream->is_set('status')
		&& $tweetstream->value('status') eq 'archived'
	);  #should never be true, but let's be explicit.

	my $search_string = $tweetstream->value('search_string');

	my $geocode = '';
	$geocode = $tweetstream->value('geocode') if $tweetstream->is_set('geocode');

	my $key = $search_string . 'XXXXXXX' . $geocode;

	if ($queue_items->{$key})
	{
		push @{$queue_items->{$key}->{tweetstreamids}}, $tweetstream->id;
		$queue_items->{$key}->{id} = join(',',sort(@{$queue_items->{$key}->{tweetstreamids}}));
	}
	else
	{
		$queue_items->{$key} = {
			id => $tweetstream->id, #id for logging
			search_params => {
				q => $search_string,
				count => 100,
				include_entities => 1,
	#			max_id => Will be set to the lowest id we find for the purposes of paging
				since_id => $tweetstream->highest_twitterid, 
			},
			tweetstreamids => [ $tweetstream->id ], #for when two streams have identical search strings
			retries => $QUERY_RETRIES, #if there's a failure, we'll try again.
		};
		#optional param
		$queue_items->{$key}->{search_params}->{geocode} = $geocode if $geocode;
	}
}


sub active_tweetstreams
{
	my ($self) = @_;

	my $ds = $self->repository->get_dataset( "tweetstream" );

	my $searchexp = EPrints::Search->new(
			session => $self->repository,
			dataset => $ds,
			);
	my $today = EPrints::Time::get_iso_date( time );
	$searchexp->add_field(
			$ds->get_field( "expiry_date" ),
			$today."-" );
#	$searchexp->add_field(
#			$ds->get_field( "status" ),
#			"active" );
	

	return $searchexp->perform_search;
}


sub get_search_rate_limit
{
	my ($nt) = @_;

	my $rl = $nt->rate_limit_status('search');

	foreach my $key (qw( resources search /search/tweets remaining ))
	{
		if (!exists $rl->{$key})
		{
			$rl = undef;
			return $rl;
		}
		$rl = $rl->{$key};
	}
	return $rl;
};





1;
