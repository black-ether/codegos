import os
import subprocess
import time
import sys
import json
import argparse
from datetime import timedelta

def format_timestamp(seconds):
    """Convert seconds to MM:SS format."""
    td = timedelta(seconds=seconds)
    minutes, seconds = divmod(int(td.total_seconds()), 60)
    return f"{minutes:02d}:{seconds:02d}"

def extract_segments_from_word_level(transcript):
    """
    Extract segments from word-level timestamps JSON structure.
    Returns a list of (start_time, text) tuples organized by paragraphs/segments.
    """
    segments = []
    current_segment_text = ""
    current_segment_start = None
    
    # Handle different possible JSON structures for word-level timestamps
    
    # Case 1: Direct list of words with timestamps
    if isinstance(transcript, list):
        for i, item in enumerate(transcript):
            if isinstance(item, dict) and "word" in item and "start" in item:
                word = item["word"].strip()
                start_time = item["start"]
                
                # If this is the first word of a segment
                if current_segment_start is None:
                    current_segment_start = start_time
                
                # Add word to current segment
                current_segment_text += word + " "
                
                # If this is the end of a sentence or the last word
                if word.endswith(('.', '!', '?')) or i == len(transcript) - 1:
                    segments.append((current_segment_start, current_segment_text.strip()))
                    current_segment_text = ""
                    current_segment_start = None
    
    # Case 2: Format with segments containing words
    elif isinstance(transcript, dict):
        if "segments" in transcript and isinstance(transcript["segments"], list):
            for segment in transcript["segments"]:
                # If segment has words
                if "words" in segment and isinstance(segment["words"], list) and segment["words"]:
                    start_time = segment["words"][0].get("start", segment.get("start", 0))
                    # Either use the segment text or compile from words
                    if "text" in segment:
                        segments.append((start_time, segment["text"].strip()))
                    else:
                        text = " ".join(word.get("word", "") for word in segment["words"])
                        segments.append((start_time, text.strip()))
                # If segment has no words but has text and start time
                elif "text" in segment and "start" in segment:
                    segments.append((segment["start"], segment["text"].strip()))
        
        # Case 3: Direct "chunks" format with words        
        elif "chunks" in transcript and isinstance(transcript["chunks"], list):
            for chunk in transcript["chunks"]:
                if "words" in chunk and isinstance(chunk["words"], list) and chunk["words"]:
                    start_time = chunk["words"][0].get("start", 0)
                    if "timestamp" in chunk["words"][0]: 
                        start_time = chunk["words"][0]["timestamp"][0]
                    
                    # Either use the chunk text or compile from words
                    if "text" in chunk:
                        segments.append((start_time, chunk["text"].strip()))
                    else:
                        text = " ".join(word.get("word", "") for word in chunk["words"])
                        segments.append((start_time, text.strip()))
                # If chunk has no words but has text and timestamp
                elif "text" in chunk:
                    start_time = 0
                    if "timestamp" in chunk and isinstance(chunk["timestamp"], list) and len(chunk["timestamp"]) > 0:
                        start_time = chunk["timestamp"][0]
                    segments.append((start_time, chunk["text"].strip()))
    
    return segments

def create_html_from_json(json_file, youtube_url, output_html=None):
    """
    Create an HTML file from Whisper JSON transcription with word-level timestamps.
    
    Args:
        json_file: Path to the JSON transcription file
        youtube_url: YouTube video URL 
        output_html: Path to save the HTML file (defaults to same name as JSON but .html)
    """
    # Set default output HTML filename if not provided
    if not output_html:
        output_html = os.path.splitext(json_file)[0] + ".html"
    
    # Clean up YouTube URL for proper timestamp linking
    if "youtu.be" in youtube_url:
        video_id = youtube_url.split("/")[-1].split("?")[0]
        base_url = f"https://www.youtube.com/watch?v={video_id}"
    elif "youtube.com" in youtube_url:
        if "watch?v=" in youtube_url:
            video_id = youtube_url.split("v=")[1].split("&")[0]
            base_url = f"https://www.youtube.com/watch?v={video_id}"
        else:
            base_url = youtube_url
    else:
        base_url = youtube_url
    
    try:
        # Load the JSON file
        with open(json_file, 'r', encoding='utf-8') as f:
            transcript = json.load(f)
        
        # Extract segments from the JSON with word-level precision
        segments = extract_segments_from_word_level(transcript)
        
        if not segments:
            print("Warning: No segments found in the JSON file. Trying fallback method...")
            # Try fallback method for parsing
            fallback_segments = []
            try:
                # Print structure of the JSON to help debugging
                print(f"JSON structure preview: {str(transcript)[:200]}...")
                
                # Try to directly find words with timestamps in the JSON
                if isinstance(transcript, dict):
                    # Look for words array
                    for key in transcript:
                        if isinstance(transcript[key], list) and len(transcript[key]) > 0:
                            first_item = transcript[key][0]
                            if isinstance(first_item, dict) and ("word" in first_item or "text" in first_item) and ("start" in first_item or "timestamp" in first_item):
                                current_text = ""
                                current_start = None
                                
                                for item in transcript[key]:
                                    word = item.get("word", item.get("text", "")).strip()
                                    start = item.get("start", None)
                                    if start is None and "timestamp" in item:
                                        start = item["timestamp"][0] if isinstance(item["timestamp"], list) else item["timestamp"]
                                    
                                    if current_start is None:
                                        current_start = start
                                    
                                    current_text += word + " "
                                    
                                    # End of sentence or segment
                                    if word.endswith(('.', '!', '?')) or len(current_text) > 80:
                                        if current_start is not None:
                                            fallback_segments.append((current_start, current_text.strip()))
                                        current_text = ""
                                        current_start = None
                                
                                # Add any remaining text
                                if current_text and current_start is not None:
                                    fallback_segments.append((current_start, current_text.strip()))
                                
                                break
                
                if fallback_segments:
                    segments = fallback_segments
                    print(f"Fallback method found {len(segments)} segments.")
                else:
                    print("Fallback method also failed. Using default segmentation.")
                    segments = [(0, "Transcript could not be parsed properly. Please check the JSON format.")]
            except Exception as e:
                print(f"Fallback parsing error: {str(e)}")
        
        # Start building the HTML
        html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Video Transcript</title>
    <style>
        body {{
            font-family: Arial, sans-serif;
            line-height: 1.6;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
        }}
        .timestamp {{
            font-weight: bold;
            color: #0366d6;
            text-decoration: none;
        }}
        .timestamp:hover {{
            text-decoration: underline;
        }}
        p {{
            margin-bottom: 16px;
        }}
    </style>
</head>
<body>
    <h1>Video Transcript</h1>
"""
        
        # Generate HTML for each segment with timestamps formatted as requested
        for start_time, text in segments:
            timestamp = format_timestamp(start_time)
            timestamp_url = f"{base_url}&t={int(start_time)}s"
            
            # Format with literal ** characters as shown in the example
            html_content += f'    <p><a class="timestamp" href="{timestamp_url}" target="_blank">**{timestamp} **</a>{text}</p>\n'
        
        # Close the HTML document
        html_content += """</body>
</html>"""
        
        # Write the HTML file
        with open(output_html, 'w', encoding='utf-8') as f:
            f.write(html_content)
        
        print(f"HTML transcript created: {output_html}")
        return True
        
    except Exception as e:
        print(f"Error creating HTML: {str(e)}")
        return False

def main():
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description="Download, transcribe with word timestamps, and create HTML from YouTube videos")
    parser.add_argument("url", help="YouTube URL to download and transcribe")
    parser.add_argument("--output-dir", default="downloads", help="Directory to save files")
    parser.add_argument("--skip-download", action="store_true", help="Skip downloading if already done")
    parser.add_argument("--skip-transcribe", action="store_true", help="Skip transcription if already done")
    parser.add_argument("--word-level", action="store_true", default=True, help="Use word-level timestamps (default: True)")
    
    args = parser.parse_args()
    
    # Create output directory if it doesn't exist
    if not os.path.exists(args.output_dir):
        os.makedirs(args.output_dir)
    
    mp3_file_path = None
    json_file_path = None
    
    # Skip download if requested and if we can find an existing MP3
    if args.skip_download:
        # Try to find an existing MP3 file (assuming there's only one in the directory)
        mp3_files = [f for f in os.listdir(args.output_dir) if f.endswith('.mp3')]
        if mp3_files:
            mp3_file_path = os.path.join(args.output_dir, mp3_files[0])
            print(f"Using existing audio file: {mp3_file_path}")
    
    # Download the audio if needed
    if not mp3_file_path:
        print(f"Downloading audio from: {args.url}")
        try:
            # Use yt-dlp to download the audio as mp3
            subprocess.run([
                "yt-dlp", 
                "-x", "--audio-format", "mp3",
                "-o", os.path.join(args.output_dir, "%(title)s.%(ext)s"),
                args.url
            ], check=True)
            
            # Get the filename of the downloaded mp3
            result = subprocess.run([
                "yt-dlp", 
                "--get-filename",
                "-o", os.path.join(args.output_dir, "%(title)s.mp3"),
                args.url
            ], capture_output=True, text=True, check=True)
            
            mp3_file_path = result.stdout.strip()
            print(f"Download completed: {mp3_file_path}")
            
        except subprocess.CalledProcessError as e:
            print(f"Error downloading video: {e}")
            return
    
    # Skip transcription if requested and if we can find an existing JSON
    if args.skip_transcribe:
        base_name, _ = os.path.splitext(mp3_file_path)
        potential_json = base_name + ".json"
        if os.path.exists(potential_json):
            json_file_path = potential_json
            print(f"Using existing transcript: {json_file_path}")
    
    # Transcribe the audio if needed
    if not json_file_path:
        # Check if insanely-fast-whisper is installed
        try:
            subprocess.run(["insanely-fast-whisper", "--help"], capture_output=True, check=False)
            whisper_installed = True
        except FileNotFoundError:
            whisper_installed = False
        
        if not whisper_installed:
            print("Warning: insanely-fast-whisper is not installed.")
            print("Install with: pip install insanely-fast-whisper torch transformers")
            print(f"Audio downloaded to: {mp3_file_path}")
            return
        
        # Transcription step using Insanely Fast Whisper
        base_name, _ = os.path.splitext(mp3_file_path)
        json_file_path = base_name + ".json"
        
        print("Starting transcription with Insanely Fast Whisper...")
        try:
            # Launch the insanely-fast-whisper CLI as a subprocess with word-level timestamps
            cmd = [
                "insanely-fast-whisper",
                "--model-name", "openai/whisper-large-v3-turbo",
                "--file-name", mp3_file_path,
                "--transcript-path", json_file_path
            ]
            
            # Add word-level timestamp flag if requested
            if args.word_level:
                cmd.extend(["--timestamp", "word"])
                print("Using word-level timestamps for more accuracy")
            
            proc = subprocess.Popen(cmd)
            
            # Provide a simple spinner progress indicator while transcribing
            spinner = ['|', '/', '-', '\\']
            idx = 0
            while proc.poll() is None:  # loop until process finishes
                print(f"\rTranscribing... {spinner[idx]}", end='', flush=True)
                idx = (idx + 1) % len(spinner)
                time.sleep(0.2)
                
            # Clear the spinner line and print completion message
            if proc.returncode == 0:
                print("\rTranscription complete.      ")
                print(f"Transcript saved as JSON: {json_file_path}")
            else:
                print(f"\rTranscription failed (exit code {proc.returncode}).")
                return
        except FileNotFoundError:
            print("ERROR: 'insanely-fast-whisper' not found. Please install it to enable transcription.")
            return
    
    # Create HTML from JSON
    html_file_path = os.path.splitext(json_file_path)[0] + ".html"
    print("Creating HTML transcript with clickable timestamps...")
    if create_html_from_json(json_file_path, args.url, html_file_path):
        print(f"Transcript HTML created successfully: {html_file_path}")
        print(f"\nOpen this file in your browser: file://{os.path.abspath(html_file_path)}")
    else:
        print("Failed to create HTML transcript.")

if __name__ == "__main__":
    main()