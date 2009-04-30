# encoding: utf-8
#--
#   Copyright (C) 2009 Nokia Corporation and/or its subsidiary(-ies)
#   Copyright (C) 2008 Johan Sørensen <johan@johansorensen.com>
#   Copyright (C) 2008 David A. Cuadrado <krawek@gmail.com>
#   Copyright (C) 2008 Tor Arne Vestbø <tavestbo@trolltech.com>
#   Copyright (C) 2009 Fabio Akita <fabio.akita@gmail.com>
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU Affero General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU Affero General Public License for more details.
#
#   You should have received a copy of the GNU Affero General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++

class MergeRequest < ActiveRecord::Base
  belongs_to :user
  belongs_to :source_repository, :class_name => 'Repository'
  belongs_to :target_repository, :class_name => 'Repository'
  has_many   :events, :as => :target, :dependent => :destroy
  has_many :messages, :as => :notifiable, :dependent => :destroy
  has_many :comments, :as => :target
  
  is_indexed :fields => ["proposal"], :include => [{
      :association_name => "user",
      :field => "login",
      :as => "proposed_by"
    }], :conditions => "status = 0"
  
  attr_protected :user_id, :status, :merge_requests_need_signoff, :oauth_path_prefix,
                  :oauth_signoff_key, :oauth_signoff_secret, :oauth_signoff_site
    
  validates_presence_of :user, :source_repository, :target_repository, :ending_commit
  
  STATUS_PENDING_ACCEPTANCE_OF_TERMS = 0
  STATUS_OPEN = 1
  STATUS_MERGED = 2
  STATUS_REJECTED = 3
  
  state_machine :status, :initial => :pending do
    state :pending, :value => ::MergeRequest::STATUS_PENDING_ACCEPTANCE_OF_TERMS
    state :open, :value => ::MergeRequest::STATUS_OPEN
    state :merged, :value => ::MergeRequest::STATUS_MERGED
    state :rejected, :value => ::MergeRequest::STATUS_REJECTED
    
    event :open do
      transition :pending => :open
    end
    
    event :reject do
      transition :open => :rejected
    end
    
    event :merge do
      transition :open => :merged
    end
  end
  
  named_scope :open, :conditions => { :status => STATUS_OPEN }
  named_scope :closed, :conditions => ["status in (?)", [STATUS_MERGED, STATUS_REJECTED]]
  
  def self.human_name
    I18n.t("activerecord.models.merge_request")
  end
  
  def self.count_open
    count(:all, :conditions => {:status => STATUS_OPEN})
  end
  
  def self.statuses
    @statuses ||= state_machines[:status].states.inject({}){ |result, state |
      result[state.name.to_s.capitalize] = state.value
      result
    }
  end
  
  def status_string
    self.class.status_string(status)
  end
  
  def self.status_string(status_code)
    statuses.invert[status_code.to_i].downcase
  end
  
  # def open?
  #   status == STATUS_OPEN
  # end
  
  # def merged?
  #   status == STATUS_MERGED
  # end
  # 
  # def rejected?
  #   status == STATUS_REJECTED
  # end
  
  def pending_acceptance_of_terms?
    pending?
  end

  def possible_next_states
    result = if status == STATUS_OPEN
      [STATUS_MERGED, STATUS_REJECTED]
    elsif status == STATUS_PENDING_ACCEPTANCE_OF_TERMS
      [STATUS_OPEN]
    else
      []
    end
    return result
  end

  def can_transition_to?(new_state)
    send("can_#{new_state}?")
  end
  
  
  def transition_to(status)
    if can_transition_to?(status)
      send(status)
      yield 
      return true
    end
  end
  
  def source_branch
    super || "master"
  end
  
  def target_branch
    super || "master"
  end
  
  def deliver_status_update(a_user)
    message = Message.new(:sender => a_user, :recipient => user, :subject => "Your merge request was updated", :body => "The merge request is now #{status_string}. \n#{reason}", :notifiable => self)
    message.save
  end
  
  def source_name
    if source_repository
      "#{source_repository.name}:#{source_branch}"
    end
  end
  
  def target_name
    if target_repository
      "#{target_repository.name}:#{target_branch}"
    end
  end
  
  def resolvable_by?(candidate)
    candidate.can_write_to?(target_repository)
  end
  
  def commits_for_selection
    return [] if !target_repository
    @commits_for_selection ||= target_repository.git.commit_deltas_from(source_repository.git, target_branch, source_branch)
  end
  
  def applies_to_specific_commits?
    !ending_commit.blank?
  end
  
  def commits_to_be_merged
    if applies_to_specific_commits?
      idx = commits_for_selection.index(commits_for_selection.find{|c| c.id == ending_commit})
      return idx ? commits_for_selection[idx..-1] : []
    else
      return commits_for_selection
    end
  end
  
  def target_branches_for_selection
    return [] unless target_repository
    target_repository.git.branches || []
  end
  
  def breadcrumb_parent
    Breadcrumb::MergeRequests.new(target_repository)
  end
  
  def breadcrumb_css_class
    "merge_request"
  end
  
  def title
    source_repository.name
  end
  
  def acceptance_of_terms_required?
    target_repository.requires_signoff_on_merge_requests?
  end
  
  def confirmed_by_user
    self.status = STATUS_OPEN
    save
    target_repository.committers.uniq.reject{|c|c == user}.each do |committer|
      message = messages.build(
        :sender => user, 
        :recipient => committer,
        :subject => I18n.t("mailer.request_notification", :login => source_repository.user.login, :title => target_repository.project.title),
        :body => proposal,
        :notifiable => self)    
      message.save
    end
  end
  
  def oauth_request_token=(token)
    self.oauth_token = token.token
    self.oauth_secret = token.secret
  end
  
  def terms_accepted
    validate_through_oauth do
      confirmed_by_user
      callback_response = access_token.post(target_repository.project.oauth_path_prefix, oauth_signoff_parameters)
      
      if Net::HTTPAccepted === callback_response
        self.contribution_notice = callback_response.body
      end
      
      contribution_agreement_version = callback_response['X-Contribution-Agreement-Version']
      update_attributes(:contribution_agreement_version => contribution_agreement_version)
    end
  end
  
  # If the contribution agreement site wants to remind the user of the current contribution license, 
  # they respond with a Net::HTTPAccepted header along with a response body containing the notice
  def contribution_notice=(notice)
    @contribution_notice = notice
  end
  
  def has_contribution_notice?
    !contribution_notice.blank?
  end
  
  def contribution_notice
    @contribution_notice
  end
  
  # Returns the parameters that are passed on to the contribution agreement site
  def oauth_signoff_parameters
    {
      'commit_id' => ending_commit, 
      'user_email' => user.email, 
      'user_login'  => user.login,
      'user_name' => URI.escape(user.title), 
      'commit_shas' => commits_to_be_merged.collect(&:id).join(","), 
      'proposal' => URI.escape(proposal), 
      'project_name' => source_repository.project.slug,
      'repository_name' => source_repository.name, 
      'merge_request_id' => id
    }
  end
  
  def validate_through_oauth
    yield if valid_oauth_credentials?
  end
  
  
  def access_token
    @access_token ||= oauth_consumer.build_access_token(oauth_token, oauth_secret)
  end
  
  def oauth_consumer
    target_repository.project.oauth_consumer
  end
  
  def valid_oauth_credentials?
    response = access_token.get("/")
    return Net::HTTPSuccess === response
  end
end
