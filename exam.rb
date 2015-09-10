require 'csv'
require 'yaml'
require 'byebug'
require 'readline'
require 'terminal-table'
require 'terminal-table/import'
require 'colorize'

class Exam
  attr_reader :results, :exercises
  def initialize(exercises)
    @exercises = exercises
    @view_options = {
      per_task: :points
    }
  end

  def self.load(hash)
    exercises = {}
    hash.each do |exercise_id, questions_hash|
      exercises[exercise_id] = Exercise.load(exercise_id, questions_hash)
    end
    exam = new(exercises)
    exercises.values.each do |exercise|
      exercise.exam = exam
    end
    exam

  end

  def read(student_id)
    er = ExamResult.new(student_id, exercises.values.map(&:read).flatten)
    er.exam = self
    @results ||= []
    @results << er
    er
  end

  def toggle_display
    @view_options[:per_task] = {
      points: :percent,
      percent: :weighted,
      weighted: :points
    }[@view_options[:per_task]]
  end

  def questions
    exercises.values.map(&:questions).flatten
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
          task_results << TaskResult.new(column_mapping[index], point.to_i)
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

  def print_table
    exercise_row = exercises.values.map do |exercise|
      value = exercise.local_id + "(#{exercise.weight})".colorize(:light_black) + "(#{'%.1f' % exercise.weighted_points_total})".colorize(:light_blue)
      {value: value, colspan: exercise.tasks.length, :alignment => :center, :border_x => "="}
    end
    questions_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        value = question.local_id + "(#{question.weight})".colorize(:light_black)  + "(#{'%.1f' % question.weighted_points_total})".colorize(:light_blue)
        {value: value, colspan: question.tasks.length, :alignment => :center}
      end
    end.flatten
    task_name_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          {value: task.local_id, :alignment => :center}
        end
      end.flatten
    end.flatten
    task_name_row += ['Σ', '%', '♫']

    task_weight_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          value = "(#{task.weight})".colorize(:light_black)
          {value: value, :alignment => :center}
        end
      end.flatten
    end.flatten

    task_weighted_total_points = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          value = ('%.1f' % task.weighted_points_total).colorize(:light_blue)
          {value: value, :alignment => :center}
        end
      end.flatten
    end.flatten


    task_value_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          {value: task.max.to_s.colorize(:light_yellow), :alignment => :center}
        end
      end.flatten
    end.flatten
    task_value_row << points_total

    student_points = per_student_task_result do |task_result|
      {value: task_result.points}
    end
    student_percentages = per_student_task_result do |task_result|
      {value: task_result.percent}
    end

    student_weighted_points = per_student_task_result do |task_result|
      {value: ( '%.1f' % task_result.weighted_points).colorize(:light_blue)}
    end

    student_rows = student_points if @view_options[:per_task] == :points
    student_rows = student_percentages if @view_options[:per_task] == :percent
    student_rows = student_weighted_points if @view_options[:per_task] == :weighted
    exercise_table = table do |t|
      t << [''] + exercise_row
      t.add_separator
      t << [''] + questions_row
      t.add_separator
      t << [''] + task_name_row
      t << [''] + task_value_row
      t << [''] + task_weight_row
      t << [''] + task_weighted_total_points
      t.add_separator
      student_rows.each do |student_row|
        t << student_row
      end
    end
    puts exercise_table
  end

  def per_student_task_result(&blk)
    student_rows = @results.map do |exam_result|
      student_row = [exam_result.student_id]
      student_row += exercises.values.map do |exercise|
        exercise.questions.values.map do |question|
          question.tasks.values.map do |task|
            task_result = exam_result.result_for(task)

            blk.call(task_result)
          end
        end.flatten
      end.flatten
      student_row << exam_result.points_total
      student_row << ("%.1f" %  exam_result.percent)
      student_row << exam_result.grade
    end
    student_rows
  end

  def score
    grades_table = table do |t|
      t << GRADES.map

      by_grade = @results.group_by(&:grade)
      t << GRADES.map do |grade|
        if by_grade[grade]
          by_grade[grade].length
        else
          0
        end
      end
      t << GRADES.map do |grade|
        if by_grade[grade]
          percent = (by_grade[grade].length / @results.length)* 100
          '%.2f' % percent
        else
          '0.00'
        end
      end

    end
    puts grades_table
  end

  def weighted_points_total
    100
  end

  def points_total
    tasks.map(&:max).inject(:+)
  end

end

Exercise = Struct.new(:local_id, :questions) do
  EXCERCISE_OPTIONS = [
    { name: 'weight', default: 1 },
    { name: 'description', default: 'Frage ohne Beschreibung' }
  ]
  attr_accessor *(EXCERCISE_OPTIONS.map{|o| o[:name]})
  attr_accessor :exam
  def self.load(question_id, hash)
    questions = {}
    hash.reject{|k, _| EXCERCISE_OPTIONS.map{|o| o[:name].to_s}.include?(k) }
      .each do |id, questions_hash|
        questions[id] = Question.load(id, questions_hash)
      end
    e = new(question_id, questions)
    questions.values.each{|q| q.exercise = e}
    EXCERCISE_OPTIONS.each do |option|
      e.instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    e
  end

  def tasks
    questions.values.map(&:tasks).map(&:values).flatten
  end

  def read
    questions.values.map(&:read).flatten
  end

  def weighted_points_total
    exam_weights_sum = exam.exercises.values.map(&:weight).inject(:+)
    exam.weighted_points_total* (self.weight.to_f / exam_weights_sum)
  end

end

Question = Struct.new(:local_id, :tasks) do
  attr_accessor :exercise
  QUESTION_OPTIONS = [
    { name: 'weight', default: 1 },
    { name: 'description', default: 'Frage ohne Beschreibung' }
  ]
  attr_accessor *(QUESTION_OPTIONS.map{|o| o[:name]})

  def self.load(id, hash)
    tasks = {}
    hash.reject{|k, _| QUESTION_OPTIONS.map{|o| o[:name].to_s}.include?(k) }
    .each do |task_id, task_hash|
      tasks[task_id] = Task.load(task_id, task_hash)
    end

    q = Question.new(id, tasks)
    tasks.values.each{|t| t.question = q}
    QUESTION_OPTIONS.each do |option|
      q.instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    q
  end

  def read
    puts " ---- #{description} ---- "
    tasks.values.map(&:read)
  end

  def weighted_points_total
    question_weights_sum = exercise.questions.values.map(&:weight).inject(:+)
    exercise.weighted_points_total * (self.weight.to_f / question_weights_sum)
  end
end

class StudentCancelledException < RuntimeError; end
class OverMaxPointsException < RuntimeError; end

Task = Struct.new(:local_id, :max) do
  attr_accessor :question
  TASK_OPTIONS = [
    { name: 'weight', default: 1 },
    { name: 'max', default: 1 },
    { name: 'description', default: 'Task ohne Beschreibung' }
  ]
  attr_accessor *(TASK_OPTIONS.map{|o| o[:name]})
  def self.load(id, hash)
    new_task = new(id)
    TASK_OPTIONS.each do |option|
      new_task.instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    new_task
  end

  def read
    print "#{description}(#{max})"
    begin
      line = Readline::readline("> ")
      raise StudentCancelledException.new if line == 'q'
      integer = Integer(line)
      raise OverMaxPointsException.new("Maximal #{max} Punkte bei dieser Aufgabe") if integer > max
      TaskResult.new(self, integer)
    rescue ArgumentError => e
      puts "Zahl zwischen 0 und #{max}!"
      read
    rescue OverMaxPointsException => e
      puts e.message
      read
    end
  end

  def global_id
    [question.exercise.local_id, question.local_id, local_id].join('-')
  end

  def weighted_points_total
    task_weights_sum = question.tasks.values.map(&:weight).inject(:+)
    question.weighted_points_total * (self.weight.to_f / task_weights_sum)
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

  def result_for(task)
    task_results.find do |task_result|
      task_result.task.global_id == task.global_id
    end
  end

  def weighted_points
    task_results.map(&:weighted_points).inject(:+)
  end

  def points_total
    task_results.map(&:points).inject(:+)
  end

  def percent
    (points_total.to_f / exam.points_total) * 100
  end

  def weighted_percent
    (weighted_points.to_f / exam.weighted_points_total) * 100
  end

  Grade = Struct.new(:percent, :color, :name) do
    def to_s
      name.colorize(color)
    end
  end
  GRADES = [
    Grade.new(92, :green, '1'),
    Grade.new(82, :green, '2'),
    Grade.new(67, :yellow, '3'),
    Grade.new(50, :yellow, '4'),
    Grade.new(30, :red, '5'),
    Grade.new(0, :red, '6')
  ]
  def grade
    p = weighted_percent
    g = GRADES.find do |grade|
      p >= grade.percent
    end
    return g
  end

end
TaskResult = Struct.new(:task, :points) do
  def to_pair
    [task.global_id, points]
  end

  def weighted_points
    (points.to_f / task.max) *task.weighted_points_total
  end

  def percent
    (points.to_f / task.max) * 100
  end
end


class Examinator
  CMDS = [
    {key: 'a', descr: 'Ansicht wechseln', method: :toggle_display},
    {key: 'l', descr: 'ErgenisListe', method: :results},
    {key: 's', descr: 'NotenSpiegel', method: :score},
    {key: 'h', descr: 'Hilfe', method: :printhelp},
    {key: 'q', descr: 'Beenden', method: :quit }
  ]

  def initialize(exam_def_file, results_file)
    examHash = YAML.load_file(exam_def_file)
    @exam = Exam.load(examHash)
    @exam.read_results(results_file)
    @result_filename = results_file
  end

  def run
    @running = true
    while @running do
      begin
        input = Readline::readline("Student (oder Kommando):").strip
        cmd = CMDS.find{|c| c[:key] == input}
        if cmd.nil?
          student_id = input
          @exam.read(student_id)
        else
          send(cmd[:method])
        end
      rescue StudentCancelledException
        puts "Aktueller Student verworfen"
      end
    end
    @exam.write(@result_filename)

  end

  def results
    @exam.print_table
  end

  def score
    @exam.score
  end

  def quit
    @running = false
  end

  def printhelp
    CMDS.each do |cmd|
      puts "#{cmd[:key]} \t - \t #{cmd[:descr]}"
    end
  end

  def toggle_display
    @exam.toggle_display
    results
  end

end


exam_def_file, results_file = ARGV
exam_def_file ||= ''
results_file ||= ''
unless exam_def_file.end_with?('.yml') && results_file.end_with?('.csv')
  puts "USAGE: exam EXAM-DEF-YAML RESULTS-CSV"
else
  Examinator.new(exam_def_file, results_file).run
end

