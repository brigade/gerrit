module Gerrit::Command
  # Push one or more commits for review.
  class Push < Base
    def execute
      # Sanity check: does this repository have a valid remote_url?
      # (this will raise an exception if that's not the case)
      remote_url = repo.remote_url

      # If an explicit ref is given, skip a bunch of the questions
      if commit_hash?(arguments[1]) || arguments[1] == 'HEAD'
        ref = arguments[1]
        reviewer_args = arguments[2..-1] || []
        type = 'publish'
        topic = nil
        target_branch = 'master'
      else
        ref = 'HEAD'
        reviewer_args = arguments[1..-1] || []
        type = ask_review_type
        topic = ask_topic
        target_branch = ask_target_branch
      end

      reviewers = extract_reviewers(reviewer_args)

      if reviewers.size >= @config.fetch(:warn_reviewer_count, 4)
        ui.newline
        ui.info("You are adding #{reviewers.size} people as reviewers for this change")

        reviewers.each do |username|
          ui.print username
        end

        until %w[y n].include?(ui.ask('Is this ok? (y/n) ')
                                 .argument(:required)
                                 .modify(:downcase)
                                 .read_string)
        end
      end

      push_changes(remote_url, ref, reviewers, target_branch, type, topic)
    end

    private

    def push_changes(remote_url, ref, reviewers, target_branch, type, topic)
      command = %W[git push #{remote_url}]

      if reviewers.any?
        reviewer_flags = reviewers.map { |reviewer| "--reviewer=#{reviewer}" }
        command += ['--receive-pack', "git receive-pack #{reviewer_flags.join(' ')}"]
      end

      destination_ref = "refs/#{type}/#{target_branch}"
      destination_ref += "/#{topic}" if topic
      command += ["#{ref}:#{destination_ref}"]

      result =
        ui.spinner('Pushing changes...') do
          spawn(command)
        end

      if result.success?
        ui.success result.stdout
        ui.success result.stderr
      else
        ui.error result.stdout
        ui.error result.stderr
      end
    end

    def extract_reviewers(reviewer_args)
      if reviewer_args.empty?
        reviewer_args = ui.ask('Enter users/groups you would like to review your changes: ')
                          .argument(:required)
                          .read_string
                          .split(/\s*,\s*/)
      end

      return [] if reviewer_args.empty?

      extract_users(reviewer_args)
    end

    def extract_users(reviewer_args)
      usernames = []
      groups = nil
      users = nil

      # HACK: We wrap these slow calls in a spinner since other parts of this
      # helper can prompt for input, which doesn't play well with the spinner
      # animation.
      ui.spinner('Finding matching users/groups...') do
        groups = client.groups
        users = client.users
      end

      reviewer_args.each do |arg|
        users_or_groups = arg.split(/\s*,\s*|\s+/)

        users_or_groups.each do |user_or_group|
          usernames += users_from_pattern(users, groups, user_or_group)
        end
      end

      usernames.uniq.sort
    end

    def users_from_pattern(users, groups, pattern)
      group_users = users_from_group(groups, pattern)

      # Don't scan users since we already matched a group
      return group_users if group_users.any?

      matching_users = users.grep(/#{pattern}/i)

      # If more than one match for an individual user, confirm which one.
      if matching_users.size >= 2
        ui.info("Multiple users match the pattern '#{pattern}':")
        matching_users.each_with_index do |username, index|
          ui.print "#{index + 1}. #{username}"
        end

        while matching_users.size >= 2
          index = ui.ask('Enter the number of the user you meant: ')
                    .argument(:required)
                    .read_int

          if index > 0 && index <= matching_users.size
            matching_users = [matching_users[index - 1]]
          end
        end
      end

      matching_users
    end

    def users_from_group(groups, group)
      matching_groups = groups.grep(/#{group}/i)

      map_in_parallel(matching_groups) do |match|
        client.group_members(match).map { |user| user[:username] }
      end.flatten.uniq
    end

    def ask_target_branch
      target = ui.ask('Target branch [master] ')
                 .modify(:trim)
                 .read_string

      target.empty? ? 'master' : target
    end

    def ask_review_type
      draft = ui.ask('Are you pushing this as a draft? (y/n) [n] ')
                .argument(:required)
                .default('n')
                .modify(:downcase)
                .read_string

      draft == 'y' ? 'drafts' : 'publish'
    end

    def ask_topic
      topic = ui.ask('Enter topic name (optional; enter * to use current branch name) ')
                .argument(:optional)
                .read_string

      topic = repo.branch('HEAD') if topic == '*'
      topic.strip.empty? ? nil : topic
    end
  end
end
