# -*- coding: utf-8 -*-
#
# A user's relationship to pages
#
# "user_participations" is the join table:
#   user has many pages through user_participations
#   page has many users through user_participations
#
module UserExtension::Pages

  ##
  ## ASSOCIATIONS
  ##

  def self.included(base)
    base.instance_eval do
      has_many :participations,
        class_name: 'UserParticipation',
        dependent: :destroy,
        inverse_of: :user

      has_many :pages, through: :participations do
        def recent_pages
          order('user_participations.changed_at DESC').limit(15)
        end
      end

      has_many :pages_owned, class_name: 'Page', as: :owner, dependent: :nullify
      has_many :pages_created, class_name: 'Page', foreign_key: :created_by_id, dependent: :nullify
      has_many :pages_updated, class_name: 'Page', foreign_key: :updated_by_id, dependent: :nullify

      def self.most_active_on(site, time)
        condition = time && ["user_participations.changed_at >= ?", time]
        joins(user_participations: :pages).
          where(condition).
          where(pages => {site_id: site}).
          where("pages.type != 'AssetPage'").
          group('users.id').
          order('count(user_participations.id) DESC').
          select('users.*, user_participations.changed_at')
      end

      def self.most_active_since(time)
        joins(:user_participations).
          group('users.id').
          order('count(user_participations.id) DESC').
          where("user_participations.changed_at >= ?", time).
          select("users.*")
      end

      def self.not_inactive
        if self.respond_to? :inactive_user_ids
          where("users.id NOT IN (?)", inactive_user_ids)
        end
      end

      # some page data objects belong to users.
      # These need has many relationships so they get cleaned up if a user
      # is destroyed.
      has_many :votes, dependent: :destroy

    end
  end

  # this is used to retrieve pages when vising
  #   /login/page_name
  # for now we only display pages the user actually owns.
  def find_page(name)
    pages_owned.where(name: name).first
  end

  ##
  ## USER PARTICIPATIONS
  ##

  #
  # makes or updates a user_participation object for a page.
  #
  # returns the user_participation, which must be saved for changed
  # to take effect.
  #
  # this method is not called directly. instead, page.add(user)
  # should be used.
  #
  # TODO: delete the user_participation row if it is not really needed
  # anymore (ie, the user won't lose access by deleted it, and inbox,
  # watch, star are all false, and the user has not contributed.)
  #
  def add_page(page, part_attrs)
    clear_access_cache
    part_attrs = part_attrs.dup
    participation = page.participation_for_user(self)
    if participation
      participation.attributes = part_attrs
    else
      # user_participations.build doesn't update the pages.users
      # until it is saved. If you need an updated users list, then
      # use user_participations directly.
      participation = page.user_participations.build(
        part_attrs.merge(
          page_id: page.id, user_id: id,
          resolved: page.resolved?
        )
      )
      participation.page = page
    end
    unless participation.changed_at or page.created_by != self
      participation.changed_at = Time.now
    end
    page.association_will_change(:users)
    participation
  end

  public

  # remove self from the page.
  # only call by page.remove(user)
  def remove_page(page)
    clear_access_cache
    page.users.delete(self)
    page.updated_by_id_will_change!
    page.association_will_change(:users)
    page.user_participations.reset
  end

  # set resolved status vis-à-vis self.
  def resolved(page, resolved_flag)
    find_or_build_participation(page).update_attributes resolved: resolved_flag
  end

  def find_or_build_participation(page)
    page.participation_for_user(self) || page.user_participations.build(user_id: self.id)
  end

  # This should be called when a user modifies a page and that modification
  # should trigger a notification to page watchers. Also, if a page state changes
  # from pending to resolved, we also update everyone's user participation.
  # The page is not saved here, because it might still get more changes.
  # An after_filter should finally save the page if it has not already been saved.
  #
  # options:
  #  :resolved -- user's participation is resolved with this page
  #  :all_resolved -- everyone's participation is resolved.
  #
  def updated(page, options={})
    return if page.blank?
    now = Time.now

    unless page.contributor?(self)
      page.contributors_count += 1
    end

    # update everyone's participation
    if options[:all_resolved]
      page.user_participations.update_all('viewed = 0, resolved = 1')
    else
      page.user_participations.update_all('viewed = 0')
    end

    # create self's participation if it does not exist
    my_part = find_or_build_participation(page)
    my_part.update_attributes(
      changed_at: now, viewed_at: now, viewed: true,
      resolved: (options[:resolved] || options[:all_resolved] || my_part.resolved?)
    )

    # this is unfortunate, because perhaps we have already just modified the page?
    page.resolved = options[:all_resolved] || page.resolved?
    page.updated_at = now
    page.updated_by = self
    page.user_participations.where(watch: true).each do |part|
      PageUpdateNotice.create!(user_id: part.user_id, page: page, from: self)
    end
  end

  ##
  ## PAGE SHARING
  ##

  public

  # share_page_with(page, recipients, options = {})
  #
  # This is the only method that should ever be used when a user is sharing a page
  # with people/groups or sending a notification to people/groups.
  #
  # An exception is thrown if there are any permissions problems.
  #
  # valid recipients:
  #
  #  array form: ['green','blue','animals']
  #  hash form: {'green' => {:access => :admin}}
  #             or {'green' => true}
  #  object form: [#<User id: 4, login: "blue">]
  #
  # There are also special recipient names that start with ":", such as :contributors.
  # See models/page_extension/create.rb parse_recipients!() for details.
  #
  # In the hash form, {"recipient_name" => "0"} is skipped. This is useful for checkboxes.
  #
  # valid options:
  #        :access -- sets access level directly. one of nil, :admin, :edit, or
  #                   :view. (nil will remove access)
  #  :grant_access -- like :access, but is only used to improve access, not remove it.
  #
  #  :send_notice  -- boolean. If true, then the page will end up in the recipient's notice list
  #                   and the following additional flags are taken into account:
  #
  #       :send_email -- boolean, send a copy of notice via email?
  #         :send_sms -- boolean, send a copy of notice vis sms? (unsupported)
  #        :send_xmpp -- boolean, send a copy of notice vis jabber? (unsupported)
  #   :send_encrypted -- boolean, only send if can be done securely (unsupported)
  #     :send_message -- text, the message to include with the notification, if any.
  #   :mailer_options -- required when sending email
  #
  # The needed user_participation and group_partication objects will get saved
  # unless page is modified, in which case they will not get saved.
  # (assuming that page.save will get called eventually, which will then save
  # the new participation objects. BasePageController has an after_filter that
  # auto saves the @page if has been changed.)
  #
  def share_page_with!(page, recipients, options = {})
    return true unless recipients
    options = HashWithIndifferentAccess.new(options)

    users_to_email = share_with_recipients!(page, recipients, options)

    ## send access granted emails (TODO)
    # emails.each do |email|
    #   Mailer::page.deliver_share_notice_with_url_access(email, msg, mailer_options)
    # end

    ## send notification emails
    if options[:send_notice] and options[:mailer_options] and options[:send_email]
      users_to_email.uniq!
      users_to_email.each do |user|
        #logger.debug '----------------- emailing %s' % user.email
        Mailer.share_notice(user, options[:send_message], options[:mailer_options]).deliver
      end
    end
  end

  #
  # check that +self+ may pester user and has admin access if sharing requires
  # granting new access.
  #
  def may_share!(page,entity,options)
    user  = entity if entity.is_a? User
    group = entity if entity.is_a? Group
    access = options[:access] || options[:grant_access] || :view
    if user
      if page.public? and !self.may?(:pester, user)
        raise PermissionDenied.new(I18n.t(:share_pester_error, name: user.login))
      elsif access.nil?
        if !user.may?(:view,page)
          raise PermissionDenied.new(I18n.t(:share_grant_required_error, name: user.login))
        end
      elsif !user.may?(access, page)
        if !self.may?(:admin,page)
          raise PermissionDenied.new(I18n.t(:share_permission_denied_error))
        elsif !self.may?(:pester, user)
          raise PermissionDenied.new(I18n.t(:share_pester_error, name: user.login))
        end
      end
    elsif group
      unless group.may?(access,page)
        unless self.may?(:admin,page) and self.may?(:pester, group)
          raise PermissionDenied.new(I18n.t(:share_pester_error, name: group.name))
        end
      end
    end
  end

  private

  def share_with_recipients!(page, recipients, options)
    if recipients.is_a?(Hash)
      share_with_recipient_hash!(page, recipients, options)
    else
      share_with_recipient_array!(page, recipients, options)
    end
  end

  # share the page, given an array of recipients, or an individual recipient.
  # returns: a list of users to notify.
  def share_with_recipient_array!(page, recipients, options)
    users, groups, emails, specials = Page.parse_recipients!(recipients)
    users_to_email = []

    ## special recipients
    specials.each do |special|
      handle_special_recipient(special, page, users, groups)
    end

    ## add users to page
    users.each do |user|
      if share_page_with_user!(page, user, options)
        users_to_email << user if user.wants_notification_email?
      end
    end

    ## add groups to page
    groups.each do |group|
      users_to_pester = share_page_with_group!(page, group, options)
      users_to_pester.each do |user|
        users_to_email << user if user.wants_notification_email?
      end
    end

    return users_to_email
  end

  #
  # takes recipients in hash form, like so {:blue => {:access => :admin}}.
  # and then calls share_with_recipient_array! with the appropriate options.
  #
  # returns an array of users to notify.
  #
  # VERY IMPORTANT NOTE: Either all the keys must be symbols or the hash types
  # must be HashWithIndifferentAccess. You have been warned.
  #
  def share_with_recipient_hash!(page, recipients, global_options=HashWithIndifferentAccess.new)
    users = []
    recipients.each do |recipient,local_options|
      if local_options == "0"
        next # skip unchecked checkboxes
      else
        options = local_options.is_a?(Hash) ? global_options.merge(local_options) : global_options
        users.concat share_with_recipient_array!(page, recipient, options)
      end
    end
    return users
  end


  # DEPRECATED
  # just like share_page_with, but don't do any actual sharing, just
  # raise an exception of there are any problems with sharing.
  def may_share_page_with!(page,recipients,options)
    return true unless recipients
    users, groups, emails = Page.parse_recipients!(recipients)
    users.each do |user|
      self.may_share!(page, user, options)
    end
    groups.each do |group|
      self.may_share!(page, group, options)
    end
  end

  #
  # share a page with another user
  #
  # see may_share!() for when a user may share a page.
  # also, we don't grant new permissions if the user already has the permissions
  # via a group membership.
  #
  # see share_page_with!() for options
  #
  def share_page_with_user!(page, user, options={})
    may_share!(page,user,options)
    attrs = {}
    if options[:send_notice]
      attrs[:viewed] = false
      PageNotice.create!(user: user, page: page, from: self, message: options[:send_message])
    end

    default_access_level = :none
    if options.key?(:access) # might be nil
      attrs[:access] = options[:access]
    else
      options[:grant_access] ||= default_access_level
      unless user.may?(options[:grant_access], page)
        attrs[:grant_access] = options[:grant_access] || default_access_level
      end
    end
    upart = page.add(user, attrs)
    upart.save! unless page.changed?
  end

  def share_page_with_group!(page, group, options={})
    may_share!(page,group,options)
    if options.key?(:access) # might be nil
      gpart = page.add(group, access: options[:access])
    else
      options[:grant_access] ||= :view
      gpart = page.add(group, grant_access: options[:grant_access])
    end
    gpart.save! unless page.changed?

    # when we get here, the group should be able to view the page.

    attrs = {}
    users_to_pester = []
    if options[:send_notice]
      attrs[:viewed] = false
      users_to_pester = group.users.with_access(self => :pester)
      users_to_pester.each do |user|
        upart = page.add(user, attrs)
        upart.save! unless page.changed?
      end
      PageNotice.create!(recipients: users_to_pester, page: page, from: self, message: options[:send_message])
    end

    users_to_pester # returns users to pester so they can get an email, maybe.
  end

  #
  # this is something of a hack, but much better than the hack it replaced.
  # in general, we have a big performance problem when trying to share/notify
  # a page with hundreds of people.
  #
  def handle_special_recipient(recipient, page, users, groups)
    if recipient == ':participants'
      groups.concat page.groups
      users.concat page.users
    elsif recipient == ':contributors'
      users.concat page.users.contributed
    elsif recipient == ':all'
      # todo
    end
  end

  public

  # return true if the user may still admin a page even if we
  # destroy the particular participation object
  #
  # this method is VERY expensive to call, and should only be called with caution.
  def may_admin_page_without?(page, participation)
    method = participation.class.name.underscore.pluralize # user_participations or group_participations
    # work with a new, untained page object
    # no changes to it should be saved!
    page = Page.find(page.id)
    page.send(method).delete_if {|part| part.id == participation.id}
    begin
      result = page.has_access!(:admin, self)
    rescue PermissionDenied
      result = false
    end
    result
  end

end
