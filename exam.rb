require 'csv'
require 'yaml'
require 'byebug'
require 'readline'

Exam = Struct.new(:exercises) do
  attr_reader :results
  def self.load(hash)
    exercises = {}
    hash.each do |exercise_id, questions_hash|
      exercises[exercise_id] = Exercise.load(exercise_id, questions_hash)
    end
    new(exercises)
  end

  def read
    student_id = Readline::readline("Student:")
    return nil if %w{q quit bye exit}.include? student_id
    er = ExamResult.new(student_id, exercises.values.map(&:read).flatten)
    er.exam = self
    @results ||= []
    @results << er
    er
  end

  def tasks
    exercises.values.map(&:tasks).flatten
  end

  def columns
    tasks.map(&:global_id)
  end

  def read_results(results_file)
    @results = []
    return unless File.exist?(results_file)
    tasks_by_id = tasks.inject({}) do |sum, task|
      sum[task.global_id] = task
      sum
    end
    column_mapping = []
    CSV.foreach(results_file) do |row|
      if column_mapping.empty?
        _, *header = row
        header.each_with_index do |header_col, index|
          task = tasks_by_id[header_col]
          raise "No task with id #{header_col} found" unless task
          column_mapping << task
        end
      else
        student_id, *points = row
        task_results = []
        points.each_with_index do |point, index|
          task_results << TaskResult.new(column_mapping[index], point)
        end
        er = ExamResult.new(student_id, task_results)
        er.exam = self
        @results << er
      end
    end
  end

  def write(results_file)
    CSV.open(results_file, "wb") do |csv|
      csv << ['student'] + columns
      @results.each do |result|
        csv << result.to_csv_row
      end
    end
  end
end

Exercise = Struct.new(:id, :questions) do
  def self.load(question_id, hash)
    questions = {}
    hash.each do |id, questions_hash|
      questions[id] = Question.load(id, questions_hash)
    end
    e = new(question_id, questions)
    questions.values.each{|q| q.exercise = e}
    e
  end

  def tasks
    questions.values.map(&:tasks).map(&:values).flatten
  end

  def read
    questions.values.map(&:read).flatten
  end
end

Question = Struct.new(:id, :description, :tasks) do
  attr_accessor :exercise
  def self.load(id, hash)
    description = hash['description']
    tasks = {}
    hash.reject{|k, _| k == 'description'}
    .each do |task_id, task_hash|
      tasks[task_id] = Task.load(task_id, task_hash)
    end

    q = Question.new(id, description, tasks)
    tasks.values.each{|t| t.question = q}
    q
  end

  def read
    puts " ---- #{description} ---- "
    tasks.values.map(&:read)
  end
end

Task = Struct.new(:id, :description, :max) do
  attr_accessor :question
  def self.load(id, hash)
    new(id, hash['description'], hash['max'])
  end

  def read
    print "#{description}(#{max})"
    line = Readline::readline("> ")
    TaskResult.new(self, line.to_i)
  end

  def global_id
    [question.exercise.id, question.id, id].join('-')
  end
end

ExamResult = Struct.new(:student_id, :task_results) do
  attr_accessor :exam
  def print
    task_results.each do |r|
      puts r.to_pair.join(':')
    end
  end

  def results_hash
    @result_hash ||= task_results.inject({}) do |sum, tr|
      sum[tr.task.global_id] = tr.points
      sum
    end
  end

  def to_csv_row
    exam.columns.inject([student_id]) do |sum, column_id|
      sum << results_hash[column_id]
    end
  end
end
TaskResult = Struct.new(:task, :points) do
  def to_pair
    [task.global_id, points]
  end
end

exam_def_file, results_file = ARGV
exam_def_file ||= ''
results_file ||= ''
unless exam_def_file.end_with?('.yml') && results_file.end_with?('.csv')
  puts "USAGE: exam EXAM-DEF-YAML RESULTS-CSV"
else
  examHash = YAML.load_file(exam_def_file)
  exam = Exam.load(examHash)
  exam.read_results(results_file)
  while exam.read do
  end
  exam.write(results_file)
end

