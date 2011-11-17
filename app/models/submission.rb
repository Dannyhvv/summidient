#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Submission < ActiveRecord::Base
  include SendToStream
  attr_protected :submitted_at
  attr_readonly :assignment_id
  belongs_to :attachment # this refers to the screenshot of the submission if it is a url submission
  belongs_to :assignment
  belongs_to :user
  belongs_to :grader, :class_name => 'User'
  belongs_to :group
  belongs_to :media_object
  belongs_to :student, :class_name => 'User', :foreign_key => :user_id
  has_many :submission_comments, :order => 'created_at', :dependent => :destroy
  has_many :visible_submission_comments, :class_name => 'SubmissionComment', :order => 'created_at', :conditions => { :hidden => false }
  has_many :assessment_requests, :as => :asset
  has_many :assigned_assessments, :class_name => 'AssessmentRequest', :as => :assessor_asset
  belongs_to :quiz_submission
  has_one :rubric_assessment, :as => :artifact, :conditions => {:assessment_type => "grading"}
  has_many :rubric_assessments, :as => :artifact
  has_many :attachment_associations, :as => :context
  has_many :attachments, :through => :attachment_associations
  serialize :turnitin_data, Hash
  validates_presence_of :assignment_id, :user_id
  validates_length_of :body, :maximum => maximum_long_text_length, :allow_nil => true, :allow_blank => true
  include CustomValidations
  validates_as_url :url
  
  named_scope :with_comments, :include => [:submission_comments ]
  named_scope :after, lambda{|date|
    {:conditions => ['submissions.created_at > ?', date] }
  }
  named_scope :before, lambda{|date|
    {:conditions => ['submissions.created_at < ?', date]}
  }
  named_scope :submitted_before, lambda{|date|
    {:conditions => ['submitted_at < ?', date] }
  }
  named_scope :submitted_after, lambda{|date|
    {:conditions => ['submitted_at > ?', date] }
  }
  
  named_scope :for_context_codes, lambda { |context_codes|
    { :conditions => {:context_code => context_codes} }
  }

  named_scope :for_conversation_participant, lambda { |p|
    # John is looking at his conversation with Jane. Show submissions where:
    #   1) John authored the submission and Jane has commented; or
    #   2) Jane authored the submission and John is an admin in the
    #      submission's course and anyone has commented and:
    #      i) no admin has commented on the submission yet, or
    #      ii) John has commented on the submission
    { :select => 'DISTINCT submissions.*',
      :joins => "INNER JOIN (
          SELECT s.id AS submission_id FROM submissions AS s
          INNER JOIN submission_comments AS sc ON sc.submission_id = s.id
            AND sc.author_id = #{p.other_participant.id}
          WHERE s.user_id = #{p.user_id}
        UNION
          SELECT DISTINCT s.id AS submission_id FROM submissions AS s
          INNER JOIN assignments AS a ON a.id = s.assignment_id
          INNER JOIN courses AS c ON c.id = a.context_id AND a.context_type = 'Course'
            AND c.workflow_state <> 'deleted'
          INNER JOIN enrollments AS e ON e.course_id = c.id AND e.user_id = #{p.user_id}
            AND e.workflow_state = 'active' AND e.type IN ('TeacherEnrollment', 'TaEnrollment')
          INNER JOIN submission_comments AS sc ON sc.submission_id = s.id
            AND (NOT s.has_admin_comment OR sc.author_id = #{p.user_id})
          WHERE s.user_id = #{p.other_participant.id})
        AS related_submissions ON related_submissions.submission_id = submissions.id"
    }
  }

  # This should only be used in the course drop down to show assignments recently graded.
  named_scope :recently_graded_assignments, lambda{|user_id, date, limit|
    {
            :select => 'assignments.id, assignments.title, assignments.points_possible, assignments.due_at,
                        submissions.grade, submissions.score, submissions.graded_at, assignments.grading_type,
                        assignments.context_id, assignments.context_type, courses.name AS context_name',
            :joins => 'JOIN assignments ON assignments.id = submissions.assignment_id
                       JOIN courses ON courses.id = assignments.context_id',
            :conditions => ["graded_at > ? AND user_id = ? AND muted = ?", date.to_s(:db), user_id, false],
            :order => 'graded_at DESC',
            :limit => limit
            }
  }

  named_scope :needs_grading, :conditions => <<-SQL
    submissions.submission_type IS NOT NULL
    AND (
      submissions.score IS NULL
      OR NOT submissions.grade_matches_current_submission
      OR submissions.workflow_state IN ('submitted', 'pending_review')
    )
    SQL
  def self.needs_grading_conditions(prefix = nil)
    conditions = needs_grading.proxy_options[:conditions].gsub(/\s+/, ' ')
    conditions.gsub!("submissions.", prefix + ".") if prefix
    conditions
  end

  
  sanitize_field :body, Instructure::SanitizeField::SANITIZE
  
  before_save :update_if_pending
  before_save :validate_single_submission, :validate_enrollment, :infer_values, :set_context_code
  before_save :prep_for_submitting_to_turnitin
  before_save :check_url_changed
  after_save :touch_user
  after_save :update_assignment
  after_save :update_attachment_associations
  after_save :queue_websnap
  after_save :update_final_score
  after_save :submit_to_turnitin_later
  after_save :update_admins_if_just_submitted

  trigger.after(:update) do |t|
    t.where('(#{Submission.needs_grading_conditions("OLD")}) <> (#{Submission.needs_grading_conditions("NEW")})') do
      <<-SQL
      UPDATE assignments
      SET needs_grading_count = needs_grading_count + CASE WHEN (#{needs_grading_conditions('NEW')}) THEN 1 ELSE -1 END
      WHERE id = NEW.assignment_id;
      SQL
    end
  end
  trigger.after(:insert) do |t|
    t.where('#{Submission.needs_grading_conditions("NEW")}') do
      <<-SQL
      UPDATE assignments
      SET needs_grading_count = needs_grading_count + 1
      WHERE id = NEW.assignment_id;
      SQL
    end
  end
  
  attr_reader :suppress_broadcast
  attr_reader :group_broadcast_submission


  has_a_broadcast_policy

  simply_versioned :explicit => true
  
  set_policy do
    given {|user| user && user.id == self.user_id }
    can :read and can :comment and can :make_group_comment and can :read_grade and can :submit
    
    given {|user| self.assignment && self.assignment.context && user && self.user &&
      self.assignment.context.observer_enrollments.find_by_user_id_and_associated_user_id_and_workflow_state(user.id, self.user.id, 'active') }
    can :read and can :read_comments
    
    given {|user, session| self.assignment.cached_context_grants_right?(user, session, :manage_grades) }#admins.include?(user) }
    can :read and can :comment and can :make_group_comment and can :read_grade and can :grade
    
    given {|user, session| self.assignment.cached_context_grants_right?(user, session, :view_all_grades) }
    can :read and can :read_grade
    
    given {|user| user && self.assessment_requests.map{|a| a.assessor_id}.include?(user.id) }
    can :read and can :comment
    
    given { |user, session|
      grants_right?(user, session, :read) &&
      turnitin_data &&
      (assignment.cached_context_grants_right?(user, session, :manage_grades) ||
        case assignment.turnitin_settings[:originality_report_visibility]
          when 'immediate': true
          when 'after_grading': current_submission_graded?
          when 'after_due_date': assignment.due_at && assignment.due_at < Time.now.utc
        end
      )
    }
    can :view_turnitin_report
  end
  
  on_update_send_to_streams do
    if self.graded_at && self.graded_at > 5.minutes.ago && !@already_sent_to_stream
      @already_sent_to_stream = true
      self.user_id
    end
  end
  
  def update_final_score
    Enrollment.send_later_if_production(:recompute_final_score, self.user_id, self.context.id) if @score_changed
    self.assignment.send_later_if_production(:multiple_module_actions, [self.user_id], :scored, self.score) if self.assignment && @score_changed
    true
  end
  
  def url
    read_body = read_attribute(:body) && CGI::unescapeHTML(read_attribute(:body))
    if read_body && read_attribute(:url) && read_body[0..250] == read_attribute(:url)[0..250]
      @full_url = read_attribute(:body)
    else
      @full_url = read_attribute(:url)
    end
  end

  def plaintext_body
    self.extend TextHelper
    strip_tags((self.body || "").gsub(/\<\s*br\s*\/\>/, "\n<br/>").gsub(/\<\/p\>/, "</p>\n"))
  end
  
  def check_turnitin_status(asset_string, attempt=1)
    self.turnitin_data ||= {}
    data = self.turnitin_data[asset_string]
    return unless data
    if !data[:similarity_score] && attempt < 10
      turnitin = Turnitin::Client.new(*self.context.turnitin_settings)
      res = turnitin.generateReport(self, asset_string)
      if res[:similarity_score]
        data[:similarity_score] = res[:similarity_score].to_f
        data[:web_overlap] = res[:web_overlap].to_f
        data[:publication_overlap] = res[:publication_overlap].to_f
        data[:student_overlap] = res[:student_overlap].to_f
        data[:state] = 'failure'
        data[:state] = 'problem' if data[:similarity_score] < 75
        data[:state] = 'warning' if data[:similarity_score] < 50
        data[:state] = 'acceptable' if data[:similarity_score] < 25
        data[:state] = 'none' if data[:similarity_score] == 0
      else
        send_at((5 * attempt).minutes.from_now, :check_turnitin_status, asset_string, attempt + 1)
      end
    else
      data[:error] = true
    end
    self.turnitin_data[asset_string] = data
    self.turnitin_data_changed!
    self.save
    data
  end
  
  def turnitin_report_url(asset_string, user)
    if self.turnitin_data && self.turnitin_data[asset_string] && self.turnitin_data[asset_string][:similarity_score]
      turnitin = Turnitin::Client.new(*self.context.turnitin_settings)
      self.send_later(:check_turnitin_status, asset_string)
      if self.grants_right?(user, nil, :grade)
        turnitin.submissionReportUrl(self, asset_string)
      elsif self.grants_right?(user, nil, :view_turnitin_report)
        turnitin.submissionStudentReportUrl(self, asset_string)
      end
    else
      nil
    end
  end
  
  def prep_for_submitting_to_turnitin
    last_attempt = self.turnitin_data && self.turnitin_data[:last_processed_attempt]
    @submit_to_turnitin = false
    if self.turnitinable? && (!last_attempt || last_attempt < self.attempt)
      self.turnitin_data ||= {}
      if self.turnitin_data[:last_processed_attempt] != self.attempt
        self.turnitin_data[:last_processed_attempt] = self.attempt
      end
      @submit_to_turnitin = true
    end
  end
  
  def submit_to_turnitin_later
    if self.turnitinable? && @submit_to_turnitin
      send_later(:submit_to_turnitin)
    end
  end
  
  def submit_to_turnitin(attempt=0)
    return unless self.context.turnitin_settings
    turnitin = Turnitin::Client.new(*self.context.turnitin_settings)
    self.turnitin_data ||= {}
    submission_response = []
    if turnitin.createOrUpdateAssignment(self.assignment)
      enrollment_response = turnitin.enrollStudent(self.context, self.user) # TODO: track this elsewhere so we don't have to do the API call on every submission
      if enrollment_response
        submission_response = turnitin.submitPaper(self)
      end
    end
    if submission_response.empty?
      send_at(5.minutes.from_now, :submit_to_turnitin, attempt + 1) if attempt < 5
    else
      true
    end
  end
  
  def turnitinable?
    if self.submission_type == 'online_upload' || self.submission_type == 'online_text_entry'
      if self.assignment.turnitin_enabled?
        return true
      end
    end
    false
  end
  
  def update_assignment
    self.send_later(:context_module_action)
    true
  end
  protected :update_assignment
  
  def context_module_action
    if self.assignment && self.user
      if self.score
        self.assignment.context_module_action(self.user, :scored, self.score)
      elsif self.submitted_at
        self.assignment.context_module_action(self.user, :submitted)
      end
    end
  end
  
  # If an object is pulled from a simply_versioned yaml it may not have a submitted at. 
  # submitted_at is needed by the SpeedGrader, so it is set to the updated_at value
  def submitted_at
    if submission_type
      if not read_attribute(:submitted_at)
        write_attribute(:submitted_at, read_attribute(:updated_at))
      end
      read_attribute(:submitted_at).in_time_zone rescue nil
    else
      nil
    end
  end
  
  def update_attachment_associations
    associations = self.attachment_associations
    association_ids = associations.map(&:attachment_id)
    ids = (Array(self.attachment_ids || "").join(',')).split(",").map{|id| id.to_i}
    ids << self.attachment_id if self.attachment_id
    ids.uniq!
    existing_associations = associations.select{|a| ids.include?(a.attachment_id) }
    (associations - existing_associations).each{|a| a.destroy }
    unassociated_ids = ids.reject{|id| association_ids.include?(id) }
    return if unassociated_ids.empty?
    attachments = Attachment.find_all_by_id(unassociated_ids)
    attachments.each do |a|
      if((a.context_type == 'User' && a.context_id == user_id) ||
          (a.context_type == 'Group' && a.context_id == group_id) ||
          (a.context_type == 'Assignment' && a.context_id == assignment_id && a.available?))
        aa = self.attachment_associations.find_by_attachment_id(a.id)
        aa ||= self.attachment_associations.create(:attachment => a)
      end
    end
  end
  
  def set_context_code
    self.context_code = self.assignment.context_code rescue nil
  end
  
  def infer_values
    if self.assignment
      self.score = self.assignment.max_score if self.assignment.max_score && self.score && self.score > self.assignment.max_score
      self.score = self.assignment.min_score if self.assignment.min_score && self.score && self.score < self.assignment.min_score 
    end
    self.submitted_at ||= Time.now if self.has_submission? || (self.submission_type && !self.submission_type.empty?)
    self.workflow_state = 'unsubmitted' if self.submitted? && !self.has_submission?
    self.workflow_state = 'graded' if self.grade && self.score && self.grade_matches_current_submission
    if self.graded? && self.graded_at_changed? && self.assignment.available?
      self.changed_since_publish = true
    end
    if self.workflow_state_changed? && self.graded?
      self.graded_at = Time.now
    end
    self.media_comment_id = nil if self.media_comment_id && self.media_comment_id.strip.empty?
    if self.media_comment_id && (self.media_comment_id_changed? || !self.media_object_id)
      mo = MediaObject.by_media_id(self.media_comment_id).first
      self.media_object_id = mo && mo.id
    end
    self.media_comment_type = nil unless self.media_comment_id
    if self.submitted_at
      self.attempt ||= 0
      self.attempt += 1 if self.submitted_at_changed?
      self.attempt = 1 if self.attempt < 1
    end
    if self.submission_type == 'online_quiz'
      self.quiz_submission ||= QuizSubmission.find_by_submission_id(self.id) rescue nil
      self.quiz_submission ||= QuizSubmission.find_by_user_id_and_quiz_id(self.user_id, self.assignment.quiz.id) rescue nil
    end
    @just_submitted = self.submitted? && self.submission_type && (self.new_record? || self.workflow_state_changed?)
    if self.score_changed?
      @score_changed = true
      if self.assignment
        self.grade = self.assignment.score_to_grade(self.score) if self.assignment.points_possible.to_f > 0.0 || self.assignment.grading_type != 'pass_fail'
      else
        self.grade = self.score.to_s
      end
    end
    
    self.process_attempts ||= 0
    self.grade = nil if !self.score
    # I think the idea of having unpublished scores is unnecessarily confusing.
    # It may be that we want to have that functionality later on, but for now
    # I say it's just confusing.
    if true #self.assignment && self.assignment.published?
      self.published_score = self.score
      self.published_grade = self.grade
    end
    true
  end
  attr_accessor :created_correctly_from_assignment_rb

  def update_admins_if_just_submitted
    if @just_submitted
      context.send_later_if_production(:resubmission_for, "assignment_#{assignment_id}")
    end
    true
  end
  
  def submission_history
    res = []
    last_submitted_at = nil
    self.versions.sort_by(&:created_at).reverse.each do |version|
      model = version.model
      if model.submitted_at && last_submitted_at.to_i != model.submitted_at.to_i
        res << model
        last_submitted_at = model.submitted_at
      end
    end
    res = self.versions.to_a[0,1].map(&:model) if res.empty?
    res.sort_by{ |s| s.submitted_at || Time.parse("Jan 1 2000") }
  end
  
  def check_url_changed
    @url_changed = self.url && self.url_changed?
    true
  end
  
  def queue_websnap
    if !self.attachment_id && @url_changed && self.url && self.submission_type == 'online_url'
      self.send_later_enqueue_args(:get_web_snapshot, { :priority => Delayed::LOW_PRIORITY })
    end
  end
  
  def attachment_ids
    read_attribute(:attachment_ids)
  end
  
  def versioned_attachments
    ids = (self.attachment_ids || "").split(",").map{|id| id.to_i}
    ids << self.attachment_id if self.attachment_id
    return [] if ids.empty?
    Attachment.find_all_by_id(ids).select{|a|
      (a.context_type == 'User' && a.context_id == user_id) || 
      (a.context_type == 'Group' && a.context_id == group_id) ||
      (a.context_type == 'Assignment' && a.context_id == assignment_id && a.available?)
    }
  end
  memoize :versioned_attachments
  
  def <=>(other)
    self.updated_at <=> other.updated_at
  end
  
  # Submission:
  #   Online submission submitted AFTER the due date (notify the teacher) - "Grade Changes"
  #   Submission graded (or published) - "Grade Changes"
  #   Grade changed - "Grade Changes"
  set_broadcast_policy do |p|
    p.dispatch :assignment_submitted_late
    p.to { assignment.context.admins_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.assignment.context.state == :available and 
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted)) and 
      record.state == :submitted and
      record.has_submission? and 
      record.assignment.due_at <= Time.now.localtime
    }
    
    p.dispatch :assignment_submitted
    p.to { assignment.context.admins_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.assignment.context.state == :available and 
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted) || record.prior_version.submitted_at != record.submitted_at) and 
      record.state == :submitted and
      record.has_submission?
    }

    p.dispatch :assignment_resubmitted
    p.to { assignment.context.admins_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.assignment.context.state == :available and 
      record.submitted? and
      record.prior_version.submitted_at and
      record.prior_version.submitted_at != record.submitted_at and
      record.has_submission? and
      # don't send a resubmitted message because we already sent a :assignment_submitted_late message.
      record.assignment.due_at > Time.now.localtime
    }

    p.dispatch :group_assignment_submitted_late
    p.to { assignment.context.admins_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.group_submission_broadcast and
      record.assignment.context.state == :available and 
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted)) and 
      record.state == :submitted and
      record.assignment.due_at <= Time.now.localtime
    }

    p.dispatch :submission_graded
    p.to { student }
    p.whenever {|record|
      !record.suppress_broadcast and
      !record.assignment.muted? and
      record.assignment.context.state == :available and 
      record.assignment.state == :published and 
      (record.changed_state_to(:graded) || (record.changed_in_state(:graded, :fields => [:score, :grade]) && !@assignment_just_published && record.assignment_graded_in_the_last_hour?))
    }
    
    p.dispatch :submission_grade_changed
    p.to { student }
    p.whenever {|record|
      !record.suppress_broadcast and
      !record.assignment.muted? and
      record.graded_at and 
      record.assignment.context.state == :available and 
      record.assignment.state == :published and 
      (!record.assignment_graded_in_the_last_hour? or record.submission_type == 'online_quiz' ) and
      (@assignment_just_published || (record.changed_in_state(:graded, :fields => [:score, :grade]) && !record.assignment_graded_in_the_last_hour?))
    }

  end
  
  def assignment_graded_in_the_last_hour?
    self.prior_version && self.prior_version.graded_at && self.prior_version.graded_at > 1.hour.ago
  end
  
  def assignment_just_published!
    @assignment_just_published = true
    self.changed_since_publish = false
    self.save!
    @assignment_just_published = false
  end
  
  def changed_since_publish?
    self.changed_since_publish
  end
  
  def teacher
    @teacher ||= self.assignment.teacher_enrollment.user
  end
  
  def update_if_pending
    @attachments = nil
    if self.submission_type == 'online_quiz' && self.quiz_submission && self.score && self.score == self.quiz_submission.score
      self.workflow_state = self.quiz_submission.complete? ? 'graded' : 'pending_review'
    end
    true
  end
  
  def attachment_ids=(ids)
    write_attribute(:attachment_ids, ids)
  end
#   def attachment_ids=(ids)
    # raise "Cannot set attachment id's directly"
  # end
  
  def attachments=(attachments)
    # Accept attachments that were already approved, those that were just created
    # or those that were part of some outside context.  This is all to prevent
    # one student from sneakily getting access to files in another user's comments,
    # since they're all being held on the assignment for now.
    attachments ||= []
    old_ids = (Array(self.attachment_ids || "").join(",")).split(",").map{|id| id.to_i}
    write_attribute(:attachment_ids, attachments.select{|a| a && a.id && old_ids.include?(a.id) || (a.recently_created? && a.context == self.assignment) || a.context != self.assignment }.map{|a| a.id}.join(","))
  end
  
  def validate_single_submission
    @full_url = nil
    if read_attribute(:url) && read_attribute(:url).length > 250
      self.body = read_attribute(:url)
      self.url = read_attribute(:url)[0..250]
    end
    self.submission_type ||= "online_url" if self.url
    self.submission_type ||= "online_text_entry" if self.body
    self.submission_type ||= "online_upload" if !self.attachments.empty?
    true
  end
  private :validate_single_submission
  
  def validate_enrollment
    begin
      self.assignment.context.students.include?(self.user) 
      true
    rescue => e
      raise ArgumentError, "Cannot submit to an assignment when the student is not properly enrolled."
    end
  end
  private :validate_enrollment

  include Workflow
  
  workflow do
    state :submitted do
      event :grade_it, :transitions_to => :graded
    end
    state :unsubmitted
    state :pending_review
    state :graded
  end
  
  named_scope :graded, lambda {
    {:conditions => ['submissions.grade IS NOT NULL']}
  }
  
  named_scope :ungraded, lambda {
    {:conditions => ['submissions.grade IS NULL'], :include => :assignment}
  }
  named_scope :having_submission, lambda {
    {:conditions => ['submissions.submission_type IS NOT NULL'] }
  }
  named_scope :include_user, lambda {
    {:include => [:user] }
  }
  named_scope :include_teacher, lambda{
    {:include => {:assignment => :teacher_enrollment} }
  }
  named_scope :include_assessment_requests, lambda {
    {:include => [:assessment_requests, :assigned_assessments] }
  }
  named_scope :include_versions, lambda{
    {:include => [:versions] }
  }
  named_scope :include_submission_comments, lambda{
    {:include => [:submission_comments] }
  }
  named_scope :speed_grader_includes, lambda{
    {:include => [:versions, :submission_comments, :attachments, :rubric_assessment]}
  }
  named_scope :for, lambda {|context|
    {:include => :assignment, :conditions => ['assignments.context_id = ? AND assignments.context_type = ?', context.id, context.class.to_s]}
  }
  named_scope :for_user, lambda {|user|
    user_id = user.is_a?(User) ? user.id : user
    {:conditions => ['submissions.user_id = ?', user_id]}
  }
  named_scope :needing_screenshot, lambda {
    {:conditions => ['submissions.submission_type = ? AND submissions.attachment_id IS NULL AND submissions.process_attempts < 3', 'online_url'], :order => :updated_at}
  }
  
  def needs_regrading?
    graded? && !grade_matches_current_submission?
  end

  def readable_state
    case workflow_state
    when 'submitted'
      t 'state.submitted', 'submitted'
    when 'unsubmitted'
      t 'state.unsubmitted', 'unsubmitted'
    when 'pending_review'
      t 'state.pending_review', 'pending review'
    when 'graded'
      t 'state.graded', 'graded'
    end
  end
  
  def grading_type
    return nil unless self.assignment
    self.assignment.grading_type
  end
  
  def readable_grade
    return nil unless grade
    case grading_type
      when 'points'
        "#{grade} out of #{assignment.points_possible}" rescue grade.capitalize 
      else
        grade.capitalize
    end
  end
  
  def last_teacher_comment
    submission_comments.reverse.find{|com| com.author_id != user_id}
  end
  
  def has_submission?
    !!self.submission_type
  end
  
  def quiz_submission_version
    return nil unless self.quiz_submission
    self.quiz_submission.versions.each do |version|
      submission = version.model
      return version.number if submission.finished_at && submission.finished_at <= self.submitted_at
    end
    nil
  end
  
  named_scope :for, lambda { |obj|
    case obj
    when User
      {:conditions => ['user_id = ?', obj]}
    else
      {}
    end
  }
  
  
  def processed?
    if submission_type == "online_url"
      return attachment && attachment.content_type.match(/image/)
    end
    false
  end
  
  def add_comment(opts={})
    opts.symbolize_keys!
    opts[:author] = opts.delete(:commenter) || opts.delete(:author) || self.user
    opts[:comment] = opts[:comment].try(:strip) || ""
    opts[:attachments] ||= opts.delete :comment_attachments
    if opts[:comment].empty? 
      if opts[:media_comment_id]
        opts[:comment] = t('media_comment', "This is a media comment.")
      elsif opts[:attachments].try(:length)
        opts[:comment] = t('attached_files_comment', "See attached files.")
      end
    end
    opts[:group_comment_id] = Digest::MD5.hexdigest((opts[:unique_key] || Date.today.to_s) + (opts[:media_comment_id] || opts[:comment] || t('no_comment', "no comment")))
    self.save! if self.new_record?
    valid_keys = [:comment, :author, :media_comment_id, :media_comment_type, :group_comment_id, :assessment_request, :attachments, :anonymous, :hidden]
    comment = self.submission_comments.create(opts.slice(*valid_keys)) if !opts[:comment].empty?
    opts[:assessment_request].comment_added(comment) if opts[:assessment_request] && comment
    comment
  end

  def limit_comments(user, session=nil)
    @comment_limiting_user = user
    @comment_limiting_session = session
  end

  def limit_if_comment_limiting_user(res)
   if @comment_limiting_user
      res = res.select{|sc| sc.grants_right?(@comment_limiting_user, @comment_limiting_session, :read) }
   end
   res
  end

  alias_method :old_submission_comments, :submission_comments
  def submission_comments(comment_scope = nil)
    res = comment_scope.nil? ? old_submission_comments : old_submission_comments.send(comment_scope)
    limit_if_comment_limiting_user(res)
  end

  alias_method :old_visible_submission_comments, :visible_submission_comments
  def visible_submission_comments
    res = old_visible_submission_comments
    limit_if_comment_limiting_user(res)
  end
  
  def assessment_request_count
    @assessment_requests_count ||= self.assessment_requests.length
  end
  
  def assigned_assessment_count
    @assigned_assessment_count ||= self.assigned_assessments.length
  end

  def assign_assessment(obj)
    @assigned_assessment_count ||= 0
    @assigned_assessment_count += 1
    assigned_assessments << obj
    touch
  end
  protected :assign_assessment

  def assign_assessor(obj)
    @assessment_request_count ||= 0
    @assessment_request_count += 1
    user = obj.user rescue nil
    association = self.assignment.rubric_association
    res = self.assessment_requests.find_or_initialize_by_assessor_asset_id_and_assessor_asset_type_and_assessor_id_and_rubric_association_id(obj.id, obj.class.to_s, user.id, (association ? association.id : nil))
    res || self.assessment_requests.build(:assessor_asset => obj, :assessor => user, :rubric_association => association)
    res.user_id = self.user_id
    res.workflow_state = 'assigned' if res.new_record?
    just_created = res.new_record?
    res.save
    case obj
    when User
      user = obj
    when Submission
      obj.assign_assessment(res) if just_created
    end
    res
  end
  
  def students
    self.group ? self.group.users : [self.user]
  end
  
  def save_without_broadcast
    @suppress_broadcast = true
    self.save!
    @suppress_broadcast = false
  end
  
  def broadcast_group_submission
    @group_broadcast_submission = true
    self.save!
    @group_broadcast_submission = false
  end
  
  # def comments
    # if @comments_user
      # res = OpenObject.process(self.comments) rescue nil
      # res ||= []
      # self.user_submission_comments.each do |comment|
        # res << OpenObject.new(
          # :user_id => comment.author_id,
          # :user_name => comment.user.name,
          # :posted_at => comment.created_at.utc.iso8601,
          # :comment => comment.comment,
          # :recipient_id => comment.user_id
        # )
      # end
      # res.sort_by{|c| c.posted_at}.to_json
    # else
      # self.comments
    # end
  # end
  
  # def comment=(comment)
    # add_comment(comment, nil)
  # end
  
  # def submission_comment=(comment)
    # add_comment(comment, self.user)
  # end
  
  def late?
    self.assignment.due_at && self.submitted_at && self.submitted_at.to_i.divmod(60)[0] > self.assignment.due_at.to_i.divmod(60)[0]
  end
  
  def graded?
    !!self.score && self.workflow_state == 'graded'
  end
  
  def current_submission_graded?
    self.graded? && (!self.submitted_at || (self.graded_at && self.graded_at >= self.submitted_at))
  end
  
  def submitted_or_graded?
    self.submitted? || self.graded?
  end
  
  def context(user=nil)
    self.assignment.context if self.assignment
  end
  
  def to_atom(opts={})
    prefix = self.assignment.context_prefix || ""
    Atom::Entry.new do |entry|
      entry.title     = "#{self.user && self.user.name} -- #{self.assignment && self.assignment.title}#{", " + self.assignment.context.name if self.assignment && opts[:include_context]}"
      entry.updated   = self.updated_at
      entry.published = self.created_at
      entry.id        = "tag:#{HostUrl.default_host},#{self.created_at.strftime("%Y-%m-%d")}:/submissions/#{self.feed_code}_#{self.updated_at.strftime("%Y-%m-%d")}"
      entry.links    << Atom::Link.new(:rel => 'alternate', 
                                    :href => "http://#{HostUrl.context_host(self.assignment.context)}/#{prefix}/assignments/#{self.assignment_id}/submissions/#{self.id}")
      entry.content   = Atom::Content::Html.new(self.body || "")
      # entry.author    = Atom::Person.new(self.user)
    end
  end

  # This little chunk makes it so that to_json will force it to always include the method :attachments
  # it is especially needed in the extended gradebook so that when we grab all of the versions through simply_versioned
  # that each of those versions include :attachments
  alias_method :ar_to_json, :to_json
  def to_json(options = {}, &block)
    if simply_versioned_version_model
      options[:methods] ||= []
      options[:methods] = Array(options[:methods])
      options[:methods] << :versioned_attachments
      options[:methods].uniq!
    end
    self.ar_to_json(options, &block)
    # default_options = { :methods => [ :attachments ]}
    # options[:methods] = [options[:methods]] if options[:methods] && !options[:methods].is_a?(Array)
    # default_options[:methods] += options[:methods] if options[:methods]
    # self.ar_to_json(options.merge(default_options), &block)
  end
  
  def self.json_serialization_full_parameters(additional_parameters={})
    additional_parameters[:comments] ||= :submission_comments
    res = {
      :methods => [:scribdable?,:conversion_status,:scribd_doc,:formatted_body,:submission_history], 
      :include => [:attachments,additional_parameters[:comments],:quiz_submission],
    }.merge(additional_parameters || {})
    if additional_parameters[:except]
      additional_parameters[:except].each do |key|
        res[:methods].delete key
        res[:include].delete key
      end
    end
    res.delete :except
    res.delete :comments
    res
  end

  def clone_for(context, dup=nil, options={})
    return nil unless params[:overwrite]
    submission = self.assignment.find_or_create_submission(self.user_id)
    self.attributes.delete_if{|k,v| [:id, :assignment_id, :user_id].include?(k.to_sym) }.each do |key, val|
      submission.send("#{key}=", val)
    end
    submission
  end
  
  def course_id=(val)
  end
  
  def to_param
    user_id
  end
  
  def turnitin_data_changed!
    @turnitin_data_changed = true
  end
  
  def changes_worth_versioning?
    !(self.changes.keys - [
      "updated_at", 
      "processed", 
      "process_attempts", 
      "changed_since_publish",
      "grade_matches_current_submission",
      "published_score",
      "published_grade"
    ]).empty? || @turnitin_data_changed
  end
  
  def get_web_snapshot
    # This should always be called in the context of a delayed job
    require 'cutycapt'
    return unless CutyCapt.enabled?
    require 'action_controller'
    require 'action_controller/test_process.rb'
    
    CutyCapt.snapshot_url(self.url, "png") do |file|
      attachment = Attachment.new(:uploaded_data => ActionController::TestUploadedFile.new(file, "image/png"))
      attachment.context = self
      attachment.save!
      attach_screenshot(attachment)
    end
  end
  
  def attach_screenshot(attachment)
    self.attachment = attachment
    self.processed = true
    self.save!
  end
end
