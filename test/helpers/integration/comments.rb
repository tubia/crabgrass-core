module Integration
  module Comments
    def post_comment(text = nil)
      text ||= Faker::Lorem.paragraph
      fill_in :post_body, with: text
      click_on "Post Message"
      text
    end

    def edit_comment(comment, new_text)
      hover_and_edit(comment) do
        fill_in :post_body, with: new_text
        click_on 'Save'
      end
      new_text
    end

    def hover_and_edit(text)
      target = page.find('.shy_parent', text: text)
      target.hover
      within ".shy_parent:hover" do
        find("a.shy", text: 'Edit').click
        yield if block_given?
      end
    end
  end
end
