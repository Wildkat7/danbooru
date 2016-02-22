require 'test_helper'

class PostTest < ActiveSupport::TestCase
  setup do
    Timecop.travel(2.weeks.ago) do
      @user = FactoryGirl.create(:user)
    end
    CurrentUser.user = @user
    CurrentUser.ip_addr = "127.0.0.1"
    MEMCACHE.flush_all
    Delayed::Worker.delay_jobs = false
  end

  teardown do
    CurrentUser.user = nil
    CurrentUser.ip_addr = nil
  end

  context "Deletion:" do
    context "Expunging a post" do
      setup do
        @post = FactoryGirl.create(:post)
      end

      context "that is status locked" do
        setup do
          @post.update_attributes({:is_status_locked => true}, :as => :admin)
        end

        should "not destroy the record" do
          @post.expunge!
          assert_equal(1, Post.where("id = ?", @post.id).count)
        end
      end

      context "that belongs to a pool" do
        setup do
          @pool = FactoryGirl.create(:pool)
          @pool.add!(@post)
          @post.reload
          @post.expunge!
        end

        should "remove the post from all pools" do
          @pool.reload
          assert_equal("", @pool.post_ids)
        end

        should "destroy the record" do
          assert_equal([], @post.errors.full_messages)
          assert_equal(0, Post.where("id = ?", @post.id).count)
        end
      end
    end

    context "Deleting a post" do
      setup do
        Danbooru.config.stubs(:blank_tag_search_fast_count).returns(nil)
      end

      context "that is status locked" do
        setup do
          @post = FactoryGirl.create(:post)
          @post.update_attributes({:is_status_locked => true}, :as => :admin)
        end

        should "fail" do
          @post.delete!
          assert_equal(["Is status locked ; cannot delete post"], @post.errors.full_messages)
          assert_equal(1, Post.where("id = ?", @post.id).count)
        end
      end

      context "with the banned_artist tag" do
        should "also ban the post" do
          post = FactoryGirl.create(:post, :tag_string => "banned_artist")
          post.delete!
          post.reload
          assert(post.is_banned?)
        end
      end

      should "update the fast count" do
        Danbooru.config.stubs(:estimate_post_counts).returns(false)
        post = FactoryGirl.create(:post, :tag_string => "aaa")
        assert_equal(1, Post.fast_count)
        assert_equal(1, Post.fast_count("aaa"))
        post.delete!
        assert_equal(1, Post.fast_count)
        assert_equal(1, Post.fast_count("aaa"))
      end

      should "toggle the is_deleted flag" do
        post = FactoryGirl.create(:post)
        assert_equal(false, post.is_deleted?)
        post.delete!
        assert_equal(true, post.is_deleted?)
      end

      should "not decrement the tag counts" do
        post = FactoryGirl.create(:post, :tag_string => "aaa")
        assert_equal(1, Tag.find_by_name("aaa").post_count)
        post.delete!
        assert_equal(1, Tag.find_by_name("aaa").post_count)
      end
    end
  end

  context "Parenting:" do
    context "Assignining a parent to a post" do
      should "update the has_children flag on the parent" do
        p1 = FactoryGirl.create(:post)
        assert(!p1.has_children?, "Parent should not have any children")
        c1 = FactoryGirl.create(:post, :parent_id => p1.id)
        p1.reload
        assert(p1.has_children?, "Parent not updated after child was added")
      end

      should "update the has_children flag on the old parent" do
        p1 = FactoryGirl.create(:post)
        p2 = FactoryGirl.create(:post)
        c1 = FactoryGirl.create(:post, :parent_id => p1.id)
        c1.parent_id = p2.id
        c1.save
        p1.reload
        p2.reload
        assert(!p1.has_children?, "Old parent should not have a child")
        assert(p2.has_children?, "New parent should have a child")
      end
    end

    context "Expunging a post with" do
      context "a parent" do
        should "reset the has_children flag of the parent" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          c1.expunge!
          p1.reload
          assert_equal(false, p1.has_children?)
        end

        should "reassign favorites to the parent" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          user = FactoryGirl.create(:user)
          c1.add_favorite!(user)
          c1.expunge!
          p1.reload
          assert(!Favorite.exists?(:post_id => c1.id, :user_id => user.id))
          assert(Favorite.exists?(:post_id => p1.id, :user_id => user.id))
          assert_equal(0, c1.score)
        end

        should "update the parent's has_children flag" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          c1.expunge!
          p1.reload
          assert(!p1.has_children?, "Parent should not have children")
        end
      end

      context "one child" do
        should "remove the parent of that child" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          p1.expunge!
          c1.reload
          assert_nil(c1.parent)
        end
      end

      context "two or more children" do
        should "reparent all children to the first child" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          c2 = FactoryGirl.create(:post, :parent_id => p1.id)
          c3 = FactoryGirl.create(:post, :parent_id => p1.id)
          p1.expunge!
          c1.reload
          c2.reload
          c3.reload
          assert_nil(c1.parent_id)
          assert_equal(c1.id, c2.parent_id)
          assert_equal(c1.id, c3.parent_id)
        end
      end
    end
    
    context "Deleting a post with" do
      context "a parent" do
        should "not reassign favorites to the parent by default" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id, :score => 1)
          user = FactoryGirl.create(:gold_user)
          c1.add_favorite!(user)
          c1.delete!
          p1.reload
          assert(Favorite.exists?(:post_id => c1.id, :user_id => user.id))
          assert(!Favorite.exists?(:post_id => p1.id, :user_id => user.id))
          assert_equal(2, c1.score)
          assert_equal(0, p1.score)
        end

        should "reassign favorites to the parent if specified" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id, :score => 1)
          user = FactoryGirl.create(:gold_user)
          c1.add_favorite!(user)
          c1.delete!(:move_favorites => true)
          p1.reload
          assert(!Favorite.exists?(:post_id => c1.id, :user_id => user.id), "Child should not still have favorites")
          assert(Favorite.exists?(:post_id => p1.id, :user_id => user.id), "Parent should have favorites")
          assert_equal(1, c1.score)
          assert_equal(1, p1.score)
        end

        should "not update the parent's has_children flag" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          c1.delete!
          p1.reload
          assert(p1.has_children?, "Parent should have children")
        end
      end

      context "one child" do
        should "not remove the has_children flag" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          p1.delete!
          p1.reload
          assert_equal(true, p1.has_children?)
        end

        should "not remove the parent of that child" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          p1.delete!
          c1.reload
          assert_not_nil(c1.parent)
        end
      end

      context "two or more children" do
        should "not reparent all children to the first child" do
          p1 = FactoryGirl.create(:post)
          c1 = FactoryGirl.create(:post, :parent_id => p1.id)
          c2 = FactoryGirl.create(:post, :parent_id => p1.id)
          c3 = FactoryGirl.create(:post, :parent_id => p1.id)
          p1.delete!
          c1.reload
          c2.reload
          c3.reload
          assert_equal(p1.id, c1.parent_id)
          assert_equal(p1.id, c2.parent_id)
          assert_equal(p1.id, c3.parent_id)
        end
      end
    end

    context "Undeleting a post with a parent" do
      should "update with a new approver" do
        new_user = FactoryGirl.create(:moderator_user)
        p1 = FactoryGirl.create(:post)
        c1 = FactoryGirl.create(:post, :parent_id => p1.id)
        c1.delete!
        CurrentUser.scoped(new_user, "127.0.0.1") do
          c1.undelete!
        end
        p1.reload
        assert_equal(new_user.id, c1.approver_id)
      end

      should "preserve the parent's has_children flag" do
        p1 = FactoryGirl.create(:post)
        c1 = FactoryGirl.create(:post, :parent_id => p1.id)
        c1.delete!
        c1.undelete!
        p1.reload
        assert_not_nil(c1.parent_id)
        assert(p1.has_children?, "Parent should have children")
      end
    end
  end

  context "Moderation:" do
    context "A deleted post" do
      setup do
        @post = FactoryGirl.create(:post, :is_deleted => true)
      end

      context "that is status locked" do
        setup do
          @post.update_attributes({:is_status_locked => true}, :as => :admin)
        end

        should "not allow undeletion" do
          @post.undelete!
          assert_equal(["Is status locked ; cannot undelete post"], @post.errors.full_messages)
          assert_equal(true, @post.is_deleted?)
        end
      end

      context "that is undeleted" do
        setup do
          @mod = FactoryGirl.create(:moderator_user)
          CurrentUser.user = @mod
        end

        context "by the approver" do
          setup do
            @post.update_attribute(:approver_id, @mod.id)
          end

          should "not be permitted" do
            assert_raises(::Post::ApprovalError) do
              @post.undelete!
            end
          end
        end

        context "by the uploader" do
          setup do
            @post.update_attribute(:uploader_id, @mod.id)
          end

          should "not be permitted" do
            assert_raises(::Post::ApprovalError) do
              @post.undelete!
            end
          end
        end
      end

      should "be undeleted" do
        @post.undelete!
        @post.reload
        assert_equal(false, @post.is_deleted?)
      end

      should "be appealed" do
        assert_difference("PostAppeal.count", 1) do
          @post.appeal!("xxx")
        end
        assert(@post.is_deleted?, "Post should still be deleted")
        assert_equal(1, @post.appeals.count)
      end
    end

    context "An approved post" do
      should "be flagged" do
        post = FactoryGirl.create(:post)
        assert_difference("PostFlag.count", 1) do
          post.flag!("bad")
        end
        assert(post.is_flagged?, "Post should be flagged.")
        assert_equal(1, post.flags.count)
      end

      should "not be flagged if no reason is given" do
        post = FactoryGirl.create(:post)
        assert_difference("PostFlag.count", 0) do
          assert_raises(PostFlag::Error) do
            post.flag!("")
          end
        end
      end
    end

    context "An unapproved post" do
      should "preserve the approver's identity when approved" do
        post = FactoryGirl.create(:post, :is_pending => true)
        post.approve!
        assert_equal(post.approver_id, CurrentUser.id)
      end

      context "that was uploaded by person X" do
        setup do
          @post = FactoryGirl.create(:post)
          @post.flag!("reason")
        end

        should "not allow person X to approve that post" do
          assert_raises(Post::ApprovalError) do
            CurrentUser.scoped(@post.uploader, "127.0.0.1") do
              @post.approve!
            end
          end

          assert_equal(["You cannot approve a post you uploaded"], @post.errors.full_messages)
        end
      end

      context "that was previously approved by person X" do
        setup do
          @user = FactoryGirl.create(:janitor_user, :name => "xxx")
          @user2 = FactoryGirl.create(:janitor_user, :name => "yyy")
          @post = FactoryGirl.create(:post, :approver_id => @user.id)
          @post.flag!("bad")
        end

        should "not allow person X to reapprove that post" do
          CurrentUser.scoped(@user, "127.0.0.1") do
            assert_raises(Post::ApprovalError) do
              @post.approve!
            end
          end
        end

        should "allow person Y to approve the post" do
          CurrentUser.scoped(@user2, "127.0.0.1") do
            assert_nothing_raised do
              @post.approve!
            end
          end
        end
      end

      context "that has been reapproved" do
        should "no longer be flagged or pending" do
          post = FactoryGirl.create(:post)
          post.flag!("bad")
          post.approve!
          assert(post.errors.empty?, post.errors.full_messages.join(", "))
          post.reload
          assert_equal(false, post.is_flagged?)
          assert_equal(false, post.is_pending?)
        end
      end
    end

    context "A status locked post" do
      setup do
        @post = FactoryGirl.create(:post)
        @post.update_attributes({:is_status_locked => true}, :as => :admin)
      end

      should "not allow new flags" do
        assert_raises(PostFlag::Error) do
          @post.flag!("wrong")
        end
      end

      should "not allow new appeals" do
        assert_raises(PostAppeal::Error) do
          @post.appeal!("wrong")
        end
      end

      should "not allow approval" do
        assert_raises(Post::ApprovalError) do
          @post.approve!
        end
      end
    end
  end

  context "Tagging:" do
    context "A post" do
      setup do
        @post = FactoryGirl.create(:post)
      end

      context "as a new user" do
        setup do
          @post.update_attribute(:tag_string, "aaa bbb ccc ddd tagme")
          CurrentUser.user = FactoryGirl.create(:user)
        end

        should "not allow you to remove tags" do
          @post.update_attributes(:tag_string => "aaa")
          assert_equal(["You must have an account at least 1 week old to remove tags"], @post.errors.full_messages)
        end

        should "allow you to remove request tags" do
          @post.update_attributes(:tag_string => "aaa bbb ccc ddd")
          @post.reload
          assert_equal("aaa bbb ccc ddd", @post.tag_string)
        end
      end

      context "with a banned artist" do
        setup do
          @artist = FactoryGirl.create(:artist)
          @artist.ban!
          @post = FactoryGirl.create(:post, :tag_string => @artist.name)
        end

        should "ban the post" do
          assert_equal(true, @post.is_banned?)
        end
      end

      context "with an artist tag that is then changed to copyright" do
        setup do
          CurrentUser.user = FactoryGirl.create(:builder_user)
          Delayed::Worker.delay_jobs = false
          @post = Post.find(@post.id)
          @post.update_attribute(:tag_string, "art:abc")
          @post = Post.find(@post.id)
          @post.update_attribute(:tag_string, "copy:abc")
          @post.reload
        end

        teardown do
          Delayed::Worker.delay_jobs = true
        end

        should "update the category of the tag" do
          assert_equal(Tag.categories.copyright, Tag.find_by_name("abc").category)
        end

        should "update the category cache of the tag" do
          assert_equal(Tag.categories.copyright, Cache.get("tc:abc"))
        end

        should "update the tag counts of the posts" do
          assert_equal(0, @post.tag_count_artist)
          assert_equal(1, @post.tag_count_copyright)
          assert_equal(0, @post.tag_count_general)
        end
      end

      context "using a tag prefix on an aliased tag" do
        setup do
          FactoryGirl.create(:tag_alias, :antecedent_name => "abc", :consequent_name => "xyz")
          @post = Post.find(@post.id)
          @post.update_attribute(:tag_string, "art:abc")
          @post.reload
        end

        should "convert the tag to its normalized version" do
          assert_equal("xyz", @post.tag_string)
        end
      end

      context "tagged with a metatag" do
        context "for a parent" do
          setup do
            @parent = FactoryGirl.create(:post)
          end

          should "update the parent relationships for both posts" do
            @post.update_attributes(:tag_string => "aaa parent:#{@parent.id}")
            @post.reload
            @parent.reload
            assert_equal(@parent.id, @post.parent_id)
            assert(@parent.has_children?)
          end
        end

        context "for a pool" do
          context "on creation" do
            setup do
              @pool = FactoryGirl.create(:pool)
              @post = FactoryGirl.create(:post, :tag_string => "aaa pool:#{@pool.id}")
            end

            should "add the post to the pool" do
              @post.reload
              @pool.reload
              assert_equal("#{@post.id}", @pool.post_ids)
              assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
            end
          end

          context "negated" do
            setup do
              @pool = FactoryGirl.create(:pool)
              @post = FactoryGirl.create(:post, :tag_string => "aaa")
              @post.add_pool!(@pool)
              @post.tag_string = "aaa -pool:#{@pool.id}"
              @post.save
            end

            should "remove the post from the pool" do
              @post.reload
              @pool.reload
              assert_equal("", @pool.post_ids)
              assert_equal("", @post.pool_string)
            end
          end

          context "id" do
            setup do
              @pool = FactoryGirl.create(:pool)
              @post.update_attributes(:tag_string => "aaa pool:#{@pool.id}")
            end

            should "add the post to the pool" do
              @post.reload
              @pool.reload
              assert_equal("#{@post.id}", @pool.post_ids)
              assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
            end
          end

          context "name" do
            context "that exists" do
              setup do
                @pool = FactoryGirl.create(:pool, :name => "abc")
                @post.update_attributes(:tag_string => "aaa pool:abc")
              end

              should "add the post to the pool" do
                @post.reload
                @pool.reload
                assert_equal("#{@post.id}", @pool.post_ids)
                assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
              end
            end

            context "that doesn't exist" do
              should "create a new pool and add the post to that pool" do
                @post.update_attributes(:tag_string => "aaa newpool:abc")
                @pool = Pool.find_by_name("abc")
                @post.reload
                assert_not_nil(@pool)
                assert_equal("#{@post.id}", @pool.post_ids)
                assert_equal("pool:#{@pool.id} pool:series", @post.pool_string)
              end
            end
          end
        end

        context "for a rating" do
          context "that is valid" do
            should "update the rating" do
              @post.update_attributes(:tag_string => "aaa rating:e")
              @post.reload
              assert_equal("e", @post.rating)
            end
          end

          context "that is invalid" do
            should "not update the rating" do
              @post.update_attributes(:tag_string => "aaa rating:z")
              @post.reload
              assert_equal("q", @post.rating)
            end
          end
        end

        context "for a fav" do
          should "add the current user to the post's favorite listing" do
            @post.update_attributes(:tag_string => "aaa fav:self")
            @post.reload
            assert_equal("fav:#{@user.id}", @post.fav_string)
          end
        end

        context "for a child" do
          setup do
            @child = FactoryGirl.create(:post)
          end

          should "update the parent relationships for both posts" do
            @post.update_attributes(:tag_string => "aaa child:#{@child.id}")
            @post.reload
            @child.reload
            assert_equal(@post.id, @child.parent_id)
            assert(@post.has_children?)
          end
        end
      end

      context "tagged with a negated tag" do
        should "remove the tag if present" do
          @post.update_attributes(:tag_string => "aaa bbb ccc")
          @post.update_attributes(:tag_string => "aaa bbb ccc -bbb")
          @post.reload
          assert_equal("aaa ccc", @post.tag_string)
        end
      end

      should "have an array representation of its tags" do
        post = FactoryGirl.create(:post)
        post.set_tag_string("aaa bbb")
        assert_equal(%w(aaa bbb), post.tag_array)
        assert_equal(%w(tag1 tag2), post.tag_array_was)
      end

      context "with large dimensions" do
        setup do
          @post.image_width = 10_000
          @post.image_height = 10
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate dimension tags added automatically" do
          assert_match(/incredibly_absurdres/, @post.tag_string)
          assert_match(/absurdres/, @post.tag_string)
          assert_match(/highres/, @post.tag_string)
        end
      end

      context "with a large file size" do
        setup do
          @post.file_size = 11.megabytes
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file size tags added automatically" do
          assert_match(/huge_filesize/, @post.tag_string)
        end
      end

      context "with a .zip file extension" do
        setup do
          @post.file_ext = "zip"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/ugoira/, @post.tag_string)
        end
      end

      context "with a .webm file extension" do
        setup do
          @post.file_ext = "webm"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/webm/, @post.tag_string)
        end
      end

      context "with a .swf file extension" do
        setup do
          @post.file_ext = "swf"
          @post.tag_string = ""
          @post.save
        end

        should "have the appropriate file type tag added automatically" do
          assert_match(/flash/, @post.tag_string)
        end
      end

      context "that has been updated" do
        should "create a new version if it's the first version" do
          assert_difference("PostVersion.count", 1) do
            post = FactoryGirl.create(:post)
          end
        end

        should "create a new version if it's been over an hour since the last update" do
          post = FactoryGirl.create(:post)
          Timecop.travel(6.hours.from_now) do
            assert_difference("PostVersion.count", 1) do
              post.update_attributes(:tag_string => "zzz")
            end
          end
        end

        should "merge with the previous version if the updater is the same user and it's been less than an hour" do
          post = FactoryGirl.create(:post)
          assert_difference("PostVersion.count", 0) do
            post.update_attributes(:tag_string => "zzz")
          end
          assert_equal("zzz", post.versions.last.tags)
        end

        should "increment the updater's post_update_count" do
          post = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")
          post.stubs(:merge_version?).returns(false)

          assert_difference("CurrentUser.post_update_count", 1) do
            post.update_attributes(:tag_string => "zzz")
            CurrentUser.reload
          end
        end

        should "reset its tag array cache" do
          post = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")
          user = FactoryGirl.create(:user)
          assert_equal(%w(aaa bbb ccc), post.tag_array)
          post.tag_string = "ddd eee fff"
          post.tag_string = "ddd eee fff"
          post.save
          assert_equal("ddd eee fff", post.tag_string)
          assert_equal(%w(ddd eee fff), post.tag_array)
        end

        should "create the actual tag records" do
          assert_difference("Tag.count", 3) do
            post = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")
          end
        end

        should "update the post counts of relevant tag records" do
          post1 = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")
          post2 = FactoryGirl.create(:post, :tag_string => "bbb ccc ddd")
          post3 = FactoryGirl.create(:post, :tag_string => "ccc ddd eee")
          assert_equal(1, Tag.find_by_name("aaa").post_count)
          assert_equal(2, Tag.find_by_name("bbb").post_count)
          assert_equal(3, Tag.find_by_name("ccc").post_count)
          post3.tag_string = "xxx"
          post3.save
          assert_equal(1, Tag.find_by_name("aaa").post_count)
          assert_equal(2, Tag.find_by_name("bbb").post_count)
          assert_equal(2, Tag.find_by_name("ccc").post_count)
          assert_equal(1, Tag.find_by_name("ddd").post_count)
          assert_equal(0, Tag.find_by_name("eee").post_count)
          assert_equal(1, Tag.find_by_name("xxx").post_count)
        end

        should "update its tag counts" do
          artist_tag = FactoryGirl.create(:artist_tag)
          copyright_tag = FactoryGirl.create(:copyright_tag)
          general_tag = FactoryGirl.create(:tag)
          new_post = FactoryGirl.create(:post, :tag_string => "#{artist_tag.name} #{copyright_tag.name} #{general_tag.name}")
          assert_equal(1, new_post.tag_count_artist)
          assert_equal(1, new_post.tag_count_copyright)
          assert_equal(1, new_post.tag_count_general)
          assert_equal(0, new_post.tag_count_character)
          assert_equal(3, new_post.tag_count)

          new_post.tag_string = "babs"
          new_post.save
          assert_equal(0, new_post.tag_count_artist)
          assert_equal(0, new_post.tag_count_copyright)
          assert_equal(1, new_post.tag_count_general)
          assert_equal(0, new_post.tag_count_character)
          assert_equal(1, new_post.tag_count)
        end

        should "merge any tag changes that were made after loading the initial set of tags part 1" do
          post = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")

          # user a adds <ddd>
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_a.tag_string = "aaa bbb ccc ddd"
          post_edited_by_user_a.save

          # user b removes <ccc> adds <eee>
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_b.tag_string = "aaa bbb eee"
          post_edited_by_user_b.save

          # final should be <aaa>, <bbb>, <ddd>, <eee>
          final_post = Post.find(post.id)
          assert_equal(%w(aaa bbb ddd eee), Tag.scan_tags(final_post.tag_string).sort)
        end

        should "merge any tag changes that were made after loading the initial set of tags part 2" do
          # This is the same as part 1, only the order of operations is reversed.
          # The results should be the same.

          post = FactoryGirl.create(:post, :tag_string => "aaa bbb ccc")

          # user a removes <ccc> adds <eee>
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_a.tag_string = "aaa bbb eee"
          post_edited_by_user_a.save

          # user b adds <ddd>
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_tag_string = "aaa bbb ccc"
          post_edited_by_user_b.tag_string = "aaa bbb ccc ddd"
          post_edited_by_user_b.save

          # final should be <aaa>, <bbb>, <ddd>, <eee>
          final_post = Post.find(post.id)
          assert_equal(%w(aaa bbb ddd eee), Tag.scan_tags(final_post.tag_string).sort)
        end

        should "merge any parent, source, and rating changes that were made after loading the initial set" do
          post = FactoryGirl.create(:post, :parent => nil, :source => nil, :rating => "q")
          parent_post = FactoryGirl.create(:post)

          # user a changes rating to safe, adds parent
          post_edited_by_user_a = Post.find(post.id)
          post_edited_by_user_a.old_parent_id = ""
          post_edited_by_user_a.old_source = ""
          post_edited_by_user_a.old_rating = "q"
          post_edited_by_user_a.parent_id = parent_post.id
          post_edited_by_user_a.source = nil
          post_edited_by_user_a.rating = "s"
          post_edited_by_user_a.save

          # user b adds source
          post_edited_by_user_b = Post.find(post.id)
          post_edited_by_user_b.old_parent_id = ""
          post_edited_by_user_b.old_source = ""
          post_edited_by_user_b.old_rating = "q"
          post_edited_by_user_b.parent_id = nil
          post_edited_by_user_b.source = "http://example.com"
          post_edited_by_user_b.rating = "q"
          post_edited_by_user_b.save

          # final post should be rated safe and have the set parent and source
          final_post = Post.find(post.id)
          assert_equal(parent_post.id, final_post.parent_id)
          assert_equal("http://example.com", final_post.source)
          assert_equal("s", final_post.rating)
        end
      end

      context "that has been tagged with a metatag" do
        should "not include the metatag in its tag string" do
          post = FactoryGirl.create(:post)
          post.tag_string = "aaa pool:1234 pool:test rating:s fav:bob"
          post.save
          assert_equal("aaa", post.tag_string)
        end
      end

      context "normalizing its source" do
        should "normalize pixiv links" do
          @post.source = "http://i2.pixiv.net/img12/img/zenze/39749565.png"
          assert_equal("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=39749565", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/img53/img/themare/39735353_big_p1.jpg"
          assert_equal("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=39735353", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/c/150x150/img-master/img/2010/11/30/08/39/58/14901720_p0_master1200.jpg"
          assert_equal("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=14901720", @post.normalized_source)

          @post.source = "http://i1.pixiv.net/img-original/img/2010/11/30/08/39/58/14901720_p0.png"
          assert_equal("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=14901720", @post.normalized_source)

          @post.source = "http://i2.pixiv.net/img-zip-ugoira/img/2014/08/05/06/01/10/44524589_ugoira1920x1080.zip"
          assert_equal("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=44524589", @post.normalized_source)
        end

        should "normalize nicoseiga links" do
          @post.source = "http://lohas.nicoseiga.jp/priv/3521156?e=1382558156&h=f2e089256abd1d453a455ec8f317a6c703e2cedf"
          assert_equal("http://seiga.nicovideo.jp/seiga/im3521156", @post.normalized_source)
          @post.source = "http://lohas.nicoseiga.jp/priv/b80f86c0d8591b217e7513a9e175e94e00f3c7a1/1384936074/3583893"
          assert_equal("http://seiga.nicovideo.jp/seiga/im3583893", @post.normalized_source)
        end

        should "normalize twitpic links" do
          @post.source = "http://d3j5vwomefv46c.cloudfront.net/photos/large/820960031.jpg?1384107199"
          assert_equal("http://twitpic.com/dks0tb", @post.normalized_source)
        end

        should "normalize deviantart links" do
          @post.source = "http://fc06.deviantart.net/fs71/f/2013/295/d/7/you_are_already_dead__by_mar11co-d6rgm0e.jpg"
          assert_equal("http://mar11co.deviantart.com/gallery/#/d6rgm0e", @post.normalized_source)
          @post.source = "http://fc00.deviantart.net/fs71/f/2013/337/3/5/35081351f62b432f84eaeddeb4693caf-d6wlrqs.jpg"
          assert_equal("http://deviantart.com/gallery/#/d6wlrqs", @post.normalized_source)
        end

        should "normalize karabako links" do
          @post.source = "http://www.karabako.net/images/karabako_38835.jpg"
          assert_equal("http://www.karabako.net/post/view/38835", @post.normalized_source)
        end

        should "normalize twipple links" do
          @post.source = "http://p.twpl.jp/show/orig/mI2c3"
          assert_equal("http://p.twipple.jp/mI2c3", @post.normalized_source)
        end

        should "normalize hentai foundry links" do
          @post.source = "http://pictures.hentai-foundry.com//a/AnimeFlux/219123.jpg"
          assert_equal("http://www.hentai-foundry.com/pictures/user/AnimeFlux/219123", @post.normalized_source)

          @post.source = "http://pictures.hentai-foundry.com/a/AnimeFlux/219123/Mobile-Suit-Equestria-rainbow-run.jpg"
          assert_equal("http://www.hentai-foundry.com/pictures/user/AnimeFlux/219123", @post.normalized_source)
        end
      end
    end
  end

  context "Favorites:" do
    context "Removing a post from a user's favorites" do
      setup do
        @user = FactoryGirl.create(:contributor_user)
        CurrentUser.user = @user
        CurrentUser.ip_addr = "127.0.0.1"
        @post = FactoryGirl.create(:post)
        @post.add_favorite!(@user)
        @user.reload
      end

      teardown do
        CurrentUser.user = nil
        CurrentUser.ip_addr = nil
      end

      should "decrement the user's favorite_count" do
        assert_difference("@user.favorite_count", -1) do
          @post.remove_favorite!(@user)
          @user.reload
        end
      end

      should "decrement the post's score for gold users" do
        @post.remove_favorite!(@user)
        @post.reload
        assert_equal(0, @post.score)
      end

      should "not decrement the post's score for basic users" do
        @member = FactoryGirl.create(:user)
        CurrentUser.scoped(@member, "127.0.0.1") do
          @post.remove_favorite!(@member)
        end
        @post.reload
        assert_equal(1, @post.score)
      end

      should "not decrement the user's favorite_count if the user did not favorite the post" do
        @post2 = FactoryGirl.create(:post)
        assert_difference("@user.favorite_count", 0) do
          @post2.remove_favorite!(@user)
          @user.reload
        end
      end
    end

    context "Adding a post to a user's favorites" do
      setup do
        @user = FactoryGirl.create(:contributor_user)
        CurrentUser.user = @user
        CurrentUser.ip_addr = "127.0.0.1"
        @post = FactoryGirl.create(:post)
      end

      teardown do
        CurrentUser.user = nil
        CurrentUser.ip_addr = nil
      end

      should "periodically clean the fav_string" do
        @post.update_column(:fav_string, "fav:1 fav:1 fav:1")
        @post.update_column(:fav_count, 3)
        @post.stubs(:clean_fav_string?).returns(true)
        @post.append_user_to_fav_string(2)
        assert_equal("fav:1 fav:2", @post.fav_string)
        assert_equal(2, @post.fav_count)
      end

      should "increment the user's favorite_count" do
        assert_difference("CurrentUser.favorite_count", 1) do
          @post.add_favorite!(@user)
          CurrentUser.reload
        end
      end

      should "increment the post's score for gold users" do
        @post.add_favorite!(@user)
        @post.reload
        assert_equal(1, @post.score)
      end

      should "not increment the post's score for basic users" do
        @member = FactoryGirl.create(:user)
        CurrentUser.scoped(@member, "127.0.0.1") do
          @post.add_favorite!(@member)
        end
        @post.reload
        assert_equal(0, @post.score)
      end

      should "update the fav strings ont he post" do
        @post.add_favorite!(@user)
        @post.reload
        assert_equal("fav:#{@user.id}", @post.fav_string)
        assert(Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        @post.add_favorite!(@user)
        @post.reload
        assert_equal("fav:#{@user.id}", @post.fav_string)
        assert(Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        @post.remove_favorite!(@user)
        @post.reload
        assert_equal("", @post.fav_string)
        assert(!Favorite.exists?(:user_id => @user.id, :post_id => @post.id))

        @post.remove_favorite!(@user)
        @post.reload
        assert_equal("", @post.fav_string)
        assert(!Favorite.exists?(:user_id => @user.id, :post_id => @post.id))
      end
    end
  end

  context "Pools:" do
    context "Removing a post from a pool" do
      should "update the post's pool string" do
        post = FactoryGirl.create(:post)
        pool = FactoryGirl.create(:pool)
        post.add_pool!(pool)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
      end
    end

    context "Adding a post to a pool" do
      should "update the post's pool string" do
        post = FactoryGirl.create(:post)
        pool = FactoryGirl.create(:pool)
        post.add_pool!(pool)
        post.reload
        assert_equal("pool:#{pool.id} pool:series", post.pool_string)
        post.add_pool!(pool)
        post.reload
        assert_equal("pool:#{pool.id} pool:series", post.pool_string)
        post.remove_pool!(pool)
        post.reload
        assert_equal("", post.pool_string)
      end
    end
  end

  context "Uploading:" do
    context "Uploading a post" do
      should "capture who uploaded the post" do
        post = FactoryGirl.create(:post)
        user1 = FactoryGirl.create(:user)
        user2 = FactoryGirl.create(:user)
        user3 = FactoryGirl.create(:user)

        post.uploader = user1
        assert_equal(user1.id, post.uploader_id)

        post.uploader_id = user2.id
        assert_equal(user2.id, post.uploader_id)
        assert_equal(user2.id, post.uploader_id)
        assert_equal(user2.name, post.uploader_name)
      end
    end
  end

  context "Searching:" do
    should "return posts for the age:<1minute tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      count = Post.tag_match("age:<1minute").count
      assert_equal(1, count)
    end

    should "return posts for the age:<1minute tag when the user is in Pacific time zone" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      Time.zone = "Pacific Time (US & Canada)"
      count = Post.tag_match("age:<1minute").count
      assert_equal(1, count)
      Time.zone = "Eastern Time (US & Canada)"
    end

    should "return posts for the age:<1minute tag when the user is in Tokyo time zone" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      Time.zone = "Asia/Tokyo"
      count = Post.tag_match("age:<1minute").count
      assert_equal(1, count)
      Time.zone = "Eastern Time (US & Canada)"
    end

    should "return posts for the ' tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "'")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      count = Post.tag_match("'").count
      assert_equal(1, count)
    end

    should "return posts for the \\ tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "\\")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      count = Post.tag_match("\\").count
      assert_equal(1, count)
    end

    should "return posts for the ( tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "(")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      count = Post.tag_match("(").count
      assert_equal(1, count)
    end

    should "return posts for the ? tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "?")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      count = Post.tag_match("?").count
      assert_equal(1, count)
    end

    should "return posts for 1 tag" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryGirl.create(:post, :tag_string => "bbb ccc")
      relation = Post.tag_match("aaa")
      assert_equal(2, relation.count)
      assert_equal(post2.id, relation.all[0].id)
      assert_equal(post1.id, relation.all[1].id)
    end

    should "return posts for a 2 tag join" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryGirl.create(:post, :tag_string => "bbb ccc")
      relation = Post.tag_match("aaa bbb")
      assert_equal(1, relation.count)
      assert_equal(post2.id, relation.first.id)
    end

    should "return posts for 1 tag with exclusion" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      post2 = FactoryGirl.create(:post, :tag_string => "aaa bbb")
      post3 = FactoryGirl.create(:post, :tag_string => "bbb ccc")
      relation = Post.tag_match("aaa -bbb")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for 1 tag with a pattern" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      post2 = FactoryGirl.create(:post, :tag_string => "aaab bbb")
      post3 = FactoryGirl.create(:post, :tag_string => "bbb ccc")
      relation = Post.tag_match("a*")
      assert_equal(2, relation.count)
      assert_equal(post2.id, relation.all[0].id)
      assert_equal(post1.id, relation.all[1].id)
    end

    should "return posts for 2 tags, one with a pattern" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      post2 = FactoryGirl.create(:post, :tag_string => "aaab bbb")
      post3 = FactoryGirl.create(:post, :tag_string => "bbb ccc")
      relation = Post.tag_match("a* bbb")
      assert_equal(1, relation.count)
      assert_equal(post2.id, relation.first.id)
    end

    should "return posts for the <id> metatag" do
      post1 = FactoryGirl.create(:post)
      post2 = FactoryGirl.create(:post)
      post3 = FactoryGirl.create(:post)
      relation = Post.tag_match("id:#{post2.id}")
      assert_equal(1, relation.count)
      assert_equal(post2.id, relation.first.id)
      relation = Post.tag_match("id:>#{post2.id}")
      assert_equal(1, relation.count)
      assert_equal(post3.id, relation.first.id)
      relation = Post.tag_match("id:<#{post2.id}")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for the <fav> metatag" do
      post1 = FactoryGirl.create(:post)
      post2 = FactoryGirl.create(:post)
      post3 = FactoryGirl.create(:post)
      user = FactoryGirl.create(:user)
      post1.add_favorite!(user)
      relation = Post.tag_match("fav:#{user.name}")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for the <pool> metatag" do
      post1 = FactoryGirl.create(:post)
      post2 = FactoryGirl.create(:post)
      post3 = FactoryGirl.create(:post)
      pool = FactoryGirl.create(:pool, :name => "xxx")
      post1.add_pool!(pool)
      relation = Post.tag_match("pool:xxx")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for the <pool> metatag with a wildcard" do
      post1 = FactoryGirl.create(:post)
      post2 = FactoryGirl.create(:post)
      post3 = FactoryGirl.create(:post)
      pool1 = FactoryGirl.create(:pool, :name => "test_a")
      pool2 = FactoryGirl.create(:pool, :name => "test_b")
      post1.add_pool!(pool1)
      post3.add_pool!(pool2)
      relation = Post.tag_match("pool:test*")
      assert_equal(2, relation.count)
      assert_equal([post3.id, post1.id], relation.all.map(&:id))
    end

    should "return posts for the <user> metatag" do
      second_user = FactoryGirl.create(:user)
      post1 = FactoryGirl.create(:post, :uploader => CurrentUser.user)

      assert_equal(CurrentUser.id, post1.uploader_id)

      CurrentUser.scoped(second_user, "127.0.0.2") do
        post2 = FactoryGirl.create(:post)
        post3 = FactoryGirl.create(:post)
      end

      relation = Post.tag_match("user:#{CurrentUser.user.name}")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for a list of md5 hashes" do
      post1 = FactoryGirl.create(:post, :md5 => "abcd")
      post2 = FactoryGirl.create(:post)
      post3 = FactoryGirl.create(:post)
      relation = Post.tag_match("md5:abcd")
      assert_equal(1, relation.count)
      assert_equal(post1.id, relation.first.id)
    end

    should "return posts for a source search" do
      post1 = FactoryGirl.create(:post, :source => "abcd")
      post2 = FactoryGirl.create(:post, :source => "abcdefg")
      post3 = FactoryGirl.create(:post, :source => "xyz")
      relation = Post.tag_match("source:abcde")
      assert_equal(1, relation.count)
      assert_equal(post2.id, relation.first.id)
    end

    should "return posts for a case insensitive source search" do
      post1 = FactoryGirl.create(:post, :source => "ABCD")
      post2 = FactoryGirl.create(:post, :source => "1234")
      relation = Post.tag_match("source:abcd")
      assert_equal(1, relation.count)
    end

    should "return posts for a pixiv source search" do
      url = "http://i1.pixiv.net/img123/img/artist-name/789.png"
      post = FactoryGirl.create(:post, :source => url)
      assert_equal(1, Post.tag_match("source:*.pixiv.net/img*/artist-name/*").count)
      assert_equal(0, Post.tag_match("source:*.pixiv.net/img*/artist-fake/*").count)
      assert_equal(1, Post.tag_match("source:http://*.pixiv.net/img*/img/artist-name/*").count)
      assert_equal(0, Post.tag_match("source:http://*.pixiv.net/img*/img/artist-fake/*").count)
      assert_equal(1, Post.tag_match("source:pixiv/artist-name/*").count)
      assert_equal(0, Post.tag_match("source:pixiv/artist-fake/*").count)
    end

    should "return posts for a pixiv id search (type 1)" do
      url = "http://i1.pixiv.net/img-inf/img/2013/03/14/03/02/36/34228050_s.jpg"
      post = FactoryGirl.create(:post, :source => url)
      assert_equal(1, Post.tag_match("pixiv_id:34228050").count)
    end

    should "return posts for a pixiv id search (type 2)" do
      url = "http://i1.pixiv.net/img123/img/artist-name/789.png"
      post = FactoryGirl.create(:post, :source => url)
      assert_equal(1, Post.tag_match("pixiv_id:789").count)
    end
    
    should "return posts for a pixiv id search (type 3)" do
      url = "http://www.pixiv.net/member_illust.php?mode=manga_big&illust_id=19113635&page=0"
      post = FactoryGirl.create(:post, :source => url)
      assert_equal(1, Post.tag_match("pixiv_id:19113635").count)
    end
    
    should "return posts for a pixiv id search (type 4)" do
      url = "http://i2.pixiv.net/img70/img/disappearedstump/34551381_p3.jpg?1364424318"
      post = FactoryGirl.create(:post, :source => url)
      assert_equal(1, Post.tag_match("pixiv_id:34551381").count)
    end
    
    # should "return posts for a pixiv novel id search" do
    #   url = "http://www.pixiv.net/novel/show.php?id=2156088"
    #   post = FactoryGirl.create(:post, :source => url)
    #   assert_equal(1, Post.tag_match("pixiv_novel_id:2156088").count)
    # end

    should "return posts for a tag subscription search" do
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      sub = FactoryGirl.create(:tag_subscription, :tag_query => "aaa", :name => "zzz")
      TagSubscription.process_all
      relation = Post.tag_match("sub:#{CurrentUser.name}")
      assert_equal(1, relation.count)
    end

    should "return posts for a <search> metatag" do
      SavedSearch.stubs(:update_listbooru_on_create)
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      sub = FactoryGirl.create(:saved_search, :tag_query => "aaa", :name => "zzz", :user_id => CurrentUser.id)
      SavedSearch.expects(:post_ids).returns([post1.id])
      relation = Post.tag_match("search:#{CurrentUser.name}")
      assert_equal(1, relation.count)
    end

    should "return posts for a named <search> metatag" do
      SavedSearch.stubs(:update_listbooru_on_create)
      post1 = FactoryGirl.create(:post, :tag_string => "aaa")
      sub = FactoryGirl.create(:saved_search, :tag_query => "aaa", :name => "zzz", :user_id => CurrentUser.id)
      SavedSearch.expects(:post_ids).returns([post1.id])
      relation = Post.tag_match("search:#{CurrentUser.name}:zzz")
      assert_equal(1, relation.count)
    end

    should "return posts for a particular rating" do
      post1 = FactoryGirl.create(:post, :rating => "s")
      post2 = FactoryGirl.create(:post, :rating => "q")
      post3 = FactoryGirl.create(:post, :rating => "e")
      relation = Post.tag_match("rating:e")
      assert_equal(1, relation.count)
      assert_equal(post3.id, relation.first.id)
    end

    should "return posts for a particular negated rating" do
      post1 = FactoryGirl.create(:post, :rating => "s")
      post2 = FactoryGirl.create(:post, :rating => "s")
      post3 = FactoryGirl.create(:post, :rating => "e")
      relation = Post.tag_match("-rating:s")
      assert_equal(1, relation.count)
      assert_equal(post3.id, relation.first.id)
    end

    should "return posts ordered by a particular attribute" do
      post1 = FactoryGirl.create(:post, :rating => "s")
      post2 = FactoryGirl.create(:post, :rating => "s")
      post3 = FactoryGirl.create(:post, :rating => "e", :score => 5, :image_width => 10_000)
      relation = Post.tag_match("order:id")
      assert_equal(post1.id, relation.first.id)
      relation = Post.tag_match("order:mpixels")
      assert_equal(post3.id, relation.first.id)
      relation = Post.tag_match("order:landscape")
      assert_equal(post3.id, relation.first.id)
    end

    should "return posts for a filesize search" do
      post = FactoryGirl.create(:post, :file_size => 1.megabyte)
      assert_equal(1, Post.tag_match("filesize:1mb").count)
      assert_equal(1, Post.tag_match("filesize:1000kb").count)
      assert_equal(1, Post.tag_match("filesize:1048576b").count)
    end

    should "not perform fuzzy matching for an exact filesize search" do
      post = FactoryGirl.create(:post, :file_size => 1.megabyte)
      assert_equal(0, Post.tag_match("filesize:1048000b").count)
      assert_equal(0, Post.tag_match("filesize:1048000").count)
    end

    should "fail for more than 6 tags" do
      post1 = FactoryGirl.create(:post, :rating => "s")

      assert_raise(::Post::SearchError) do
        Post.tag_match("a b c rating:s width:10 height:10 user:bob")
      end
    end

    should "succeed for exclusive tag searches with no other tag" do
      post1 = FactoryGirl.create(:post, :rating => "s", :tag_string => "aaa")
      assert_nothing_raised do
        relation = Post.tag_match("-aaa")
      end
    end

    should "succeed for exclusive tag searches combined with a metatag" do
      post1 = FactoryGirl.create(:post, :rating => "s", :tag_string => "aaa")
      assert_nothing_raised do
        relation = Post.tag_match("-aaa id:>0")
      end
    end
  end

  context "Voting:" do
    context "with a super voter" do
      setup do
        @user = FactoryGirl.create(:user)
        FactoryGirl.create(:super_voter, user: @user)
        @post = FactoryGirl.create(:post)
      end
      
      should "account for magnitude" do
        CurrentUser.scoped(@user, "127.0.0.1") do
          assert_nothing_raised {@post.vote!("up")}
          assert_raises(PostVote::Error) {@post.vote!("up")}
          @post.reload
          assert_equal(1, PostVote.count)
          assert_equal(SuperVoter::MAGNITUDE, @post.score)
        end
      end
    end

    should "not allow duplicate votes" do
      user = FactoryGirl.create(:user)
      post = FactoryGirl.create(:post)
      CurrentUser.scoped(user, "127.0.0.1") do
        assert_nothing_raised {post.vote!("up")}
        assert_raises(PostVote::Error) {post.vote!("up")}
        post.reload
        assert_equal(1, PostVote.count)
        assert_equal(1, post.score)
      end
    end

    should "allow undoing of votes" do
      user = FactoryGirl.create(:user)
      post = FactoryGirl.create(:post)
      CurrentUser.scoped(user, "127.0.0.1") do
        post.vote!("up")
        post.unvote!
        post.reload
        assert_equal(0, post.score)
        assert_nothing_raised {post.vote!("down")}
      end
    end
  end

  context "Counting:" do
    context "Creating a post" do
      setup do
        Danbooru.config.stubs(:blank_tag_search_fast_count).returns(nil)
        Danbooru.config.stubs(:estimate_post_counts).returns(false)
      end

      context "with a primed cache" do
        setup do
          Cache.put("pfc:aaa", 0)
          Cache.put("pfc:alias", 0)
          Cache.put("pfc:width:50", 0)
          Danbooru.config.stubs(:blank_tag_search_fast_count).returns(1_000_000)
          FactoryGirl.create(:tag_alias, :antecedent_name => "alias", :consequent_name => "aaa")
          FactoryGirl.create(:post, :tag_string => "aaa")
        end

        should "be counted correctly in fast_count" do
          assert_equal(1, Post.count)
          assert_equal(1, Post.fast_count(""))
          assert_equal(1, Post.fast_count("aaa"))
          assert_equal(1, Post.fast_count("alias"))
          assert_equal(0, Post.fast_count("bbb"))
        end
      end

      should "increment the post count" do
        assert_equal(0, Post.fast_count(""))
        post = FactoryGirl.create(:post, :tag_string => "aaa bbb")
        assert_equal(1, Post.fast_count(""))
        assert_equal(1, Post.fast_count("aaa"))
        assert_equal(1, Post.fast_count("bbb"))
        assert_equal(0, Post.fast_count("ccc"))

        post.tag_string = "ccc"
        post.save

        assert_equal(1, Post.fast_count(""))
        assert_equal(0, Post.fast_count("aaa"))
        assert_equal(0, Post.fast_count("bbb"))
        assert_equal(1, Post.fast_count("ccc"))
      end
    end

    context "The cache" do
      context "when shared between users on danbooru/safebooru" do
        setup do
          Danbooru.config.stubs(:blank_tag_search_fast_count).returns(nil)
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :rating => "q")
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :rating => "s")
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :rating => "s")
          CurrentUser.stubs(:safe_mode?).returns(true)
          Post.fast_count("aaa")
          CurrentUser.stubs(:safe_mode?).returns(false)
          Post.fast_count("bbb")
        end

        should "be accurate on danbooru" do
          CurrentUser.stubs(:safe_mode?).returns(false)
          assert_equal(3, Post.fast_count("aaa"))
          assert_equal(3, Post.fast_count("bbb"))
        end

        should "be accurate on safebooru" do
          CurrentUser.stubs(:safe_mode?).returns(true)
          assert_equal(2, Post.fast_count("aaa"))
          assert_equal(2, Post.fast_count("bbb"))
        end
      end

      context "when shared between users with the deleted post filter on/off" do
        setup do
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :is_deleted => true)
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :is_deleted => false)
          FactoryGirl.create(:post, :tag_string => "aaa bbb", :is_deleted => false)
          CurrentUser.user.stubs(:hide_deleted_posts?).returns(true)
          Post.fast_count("aaa")
          CurrentUser.user.stubs(:hide_deleted_posts?).returns(false)
          Post.fast_count("bbb")
        end

        should "be accurate with the deleted post filter on" do
          CurrentUser.user.stubs(:hide_deleted_posts?).returns(true)
          assert_equal(2, Post.fast_count("aaa"))
          assert_equal(2, Post.fast_count("bbb"))
        end

        should "be accurate with the deleted post filter off" do
          CurrentUser.user.stubs(:hide_deleted_posts?).returns(false)
          assert_equal(3, Post.fast_count("aaa"))
          assert_equal(3, Post.fast_count("bbb"))
        end
      end
    end
  end

  context "Reverting: " do
    context "a post that has been updated" do
      setup do
        @post = FactoryGirl.create(:post, :rating => "q", :tag_string => "aaa")
        @post.stubs(:merge_version?).returns(false)
        @post.update_attributes(:tag_string => "aaa bbb ccc ddd")
        @post.update_attributes(:tag_string => "bbb xxx yyy", :source => "xyz")
        @post.update_attributes(:tag_string => "bbb mmm yyy", :source => "abc")
      end

      context "and then reverted to an early version" do
        setup do
          @post.revert_to(@post.versions[1])
        end

        should "correctly revert all fields" do
          assert_equal("aaa bbb ccc ddd", @post.tag_string)
          assert_equal(nil, @post.source)
          assert_equal("q", @post.rating)
        end
      end

      context "and then reverted to a later version" do
        setup do
          @post.revert_to(@post.versions[-2])
        end

        should "correctly revert all fields" do
          assert_equal("bbb xxx yyy", @post.tag_string)
          assert_equal("xyz", @post.source)
          assert_equal("q", @post.rating)
        end
      end
    end
  end
end

