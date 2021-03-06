class UserMailer < ApplicationMailer
  add_template_helper ApplicationHelper
  add_template_helper UsersHelper

  def dmail_notice(dmail)
    @dmail = dmail
    mail(:to => "#{dmail.to.name} <#{dmail.to.email}>", :subject => "#{Danbooru.config.app_name} - Message received from #{dmail.from.name}")
  end

  def password_reset(user)
    @user = user
    mail to: "#{@user.name} <#{@user.email}>", subject: "#{Danbooru.config.app_name} password reset request"
  end
end
