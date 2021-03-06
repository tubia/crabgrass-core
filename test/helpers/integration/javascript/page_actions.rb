# These currently only work with javascript.
module PageActions

  PERMISSION_ICONS = {
    'Write Ability' => :pencil,
    'Read Only' => :no_pencil,
    'Full Access' => :wrench
  }

  def share_page_with(*entities)
    click_on 'Share Page'
    add_recipients *entities, autocomplete: true
    click_on 'Share'
    # wait until sharing completed...
    find '.names', text: entities.last.display_name
    # there may still be autocomplete queries pending if the entity
    # was preloaded
    wait_for_ajax
  end

  def tag_page(tags)
    tags = tags.join(', ') if tags.respond_to? :join
    within '#tag_li' do
      click_on 'Edit'
    end
    fill_in 'add', with: tags
    click_on 'Add'
  end

  def remove_page_tag(tag)
    within '#tag_li' do
      click_on 'Edit'
    end
    find('span', text: tag).hover
    within ".shy_parent:hover" do
      click_on 'Remove'
    end
    click_button 'Close'
  end

  def star_page
    click_on 'Add Star (0)'
  end

  def remove_star_from_page
    click_on 'Remove Star (1)'
  end

  def watch_page
    click_on 'Watch For Updates'
  end

  def unwatch_page
    click_on 'Watch For Updates'
  end

  def change_access_to(permission)
    click_on 'Page Details'
    find('a', text: 'Permissions').click
    select permission
    assert_selector "#permissions_tab .tiny_#{PERMISSION_ICONS[permission]}_16"
    close_popup
    wait_for_ajax # reload sidebar
  end

  def delete_page(page = @page)
    click_on 'Delete Page'
    click_button 'Delete'
    # ensure after_commit callbacks are triggered so sphinx indexes the page.
    page.page_terms.committed!
  end

  def undelete_page(page = @page)
    click_on 'Undelete'
    # ensure after_commit callbacks are triggered so sphinx indexes the page.
    page.page_terms.committed!
  end

  def attach_file_to_page(file = fixture_file('photo.jpg'), page = @page)
    within '#attachments' do
      click_on 'Edit'
    end
    attach_file 'upload-input', file
    assert_selector '#assets_list li.asset'
    close_popup
  end

  def remove_file_from_page
    within '#attachments' do
      click_on 'Edit'
    end
    find('#assets_list li.asset .trash_16').click
    click_on 'OK'
  end

  # verify that the little thumbnail image actually gets displayed
  def check_attachment_thumbnail
    find("#attachments a.thumbnail img").synchronize do
      unless evaluate_script("$$('#attachments a.thumbnail img').first().naturalWidth != 0")
        raise Capybara::ExpectationNotMet.new("Thumbnail could not be loaded")
      end
    end
  end

  def close_popup
    find('#MB_content').click_on 'Close'
    assert_no_selector '#MB_window'
  end

  #
  # Add recipients in the page creation or share forms
  #
  # options:
  #
  # autocomplete: use the autocomplete popup. This will fail if
  #               the user in question is not visible.
  #
  def add_recipients(*args)
    options = args.extract_options!
    args.each do |recipient|
      add_recipient(recipient, options)
    end
  end

  def add_recipient(recipient, options = {})
    if options[:autocomplete]
      autocomplete :recipient_name, with: recipient.name
    else
      # the space is a work around as the first letter may get cut off
      fill_in :recipient_name, with: ' ' + recipient.name
      find('#add_recipient_button').click
    end
    # this may be in an error message or the list of shares.
    assert_content recipient.name
    # make sure all the autocomplete requests have been responded to
    # before we move on...
    wait_for_ajax
  end
end
